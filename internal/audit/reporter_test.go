package audit

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"
)

func TestMatchOne(t *testing.T) {
	cases := []struct {
		typ, value, target string
		want               bool
	}{
		{"domain", "example.com", "example.com", true},
		{"domain", "example.com", "www.example.com", false},
		{"domain_suffix", "example.com", "example.com", true},
		{"domain_suffix", "example.com", "www.example.com", true},
		{"domain_suffix", "example.com", "notexample.com", false},
		{"keyword", "porn", "free-porn-site.com", true},
		{"keyword", "porn", "example.com", false},
		{"ip_cidr", "1.2.3.0/24", "1.2.3.4", true},
		{"ip_cidr", "1.2.3.0/24", "1.2.4.4", false},
		{"ip_cidr", "1.2.3.4", "1.2.3.4", true}, // 无斜杠 = 精确匹配
		{"unknown", "x", "x", false},
	}
	for _, c := range cases {
		if got := matchOne(c.typ, c.value, c.target); got != c.want {
			t.Errorf("matchOne(%q,%q,%q)=%v want %v", c.typ, c.value, c.target, got, c.want)
		}
	}
}

// TestResolveSizes covers the explicit-value-wins contract: a user who sets
// batch_max/queue_cap explicitly must keep their value, even when it happens
// to equal the non-report_all default.
func TestResolveSizes(t *testing.T) {
	cases := []struct {
		name              string
		cfg               Config
		wantBatch, wantQ  int
	}{
		{
			name: "zero values get default",
			cfg:  Config{},
			wantBatch: defaultBatchMax, wantQ: defaultQueueCap,
		},
		{
			name: "zero values get report_all default",
			cfg:  Config{ReportAll: true},
			wantBatch: reportAllBatchMax, wantQ: reportAllQueueCap,
		},
		{
			name: "explicit 50 kept under report_all",
			// 回归：旧实现用 `== 50` 反推"未配置"，会把这里的 50 改写成 200
			cfg:  Config{ReportAll: true, BatchMax: 50, QueueCap: 5000},
			wantBatch: 50, wantQ: 5000,
		},
		{
			name: "explicit custom kept under report_all",
			cfg:  Config{ReportAll: true, BatchMax: 12, QueueCap: 999},
			wantBatch: 12, wantQ: 999,
		},
		{
			name: "explicit custom kept without report_all",
			cfg:  Config{BatchMax: 7, QueueCap: 321},
			wantBatch: 7, wantQ: 321,
		},
		{
			name: "negative treated as unset",
			cfg:  Config{BatchMax: -1, QueueCap: -5},
			wantBatch: defaultBatchMax, wantQ: defaultQueueCap,
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			gotBatch, gotQ := resolveSizes(c.cfg)
			if gotBatch != c.wantBatch {
				t.Errorf("batchMax = %d, want %d", gotBatch, c.wantBatch)
			}
			if gotQ != c.wantQ {
				t.Errorf("queueCap = %d, want %d", gotQ, c.wantQ)
			}
		})
	}
}

// TestNewKeepsExplicitSizes verifies New() preserves explicit sizes end to end.
//
// Uses an httptest server rather than a fake base URL: New() starts the loop
// goroutine immediately, and a bogus host would leave it retrying against a
// dead address for the rest of the test binary's lifetime (polluting other
// tests' logs). A live stub keeps the goroutine harmless.
func TestNewKeepsExplicitSizes(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		switch req.URL.Path {
		case rulesPath:
			io.WriteString(w, `{"data":[]}`)
		default:
			io.WriteString(w, `{"data":{}}`)
		}
	}))
	defer srv.Close()

	r := New(Config{Enabled: true, ReportAll: true, BatchMax: 50, QueueCap: 5000},
		PanelAuth{BaseURL: srv.URL, Token: "t", NodeID: 1})
	if !r.Enabled() {
		t.Fatal("expected enabled")
	}
	if r.cfg.BatchMax != 50 {
		t.Errorf("BatchMax = %d, want 50 (explicit value must win)", r.cfg.BatchMax)
	}
	if r.cfg.QueueCap != 5000 {
		t.Errorf("QueueCap = %d, want 5000 (explicit value must win)", r.cfg.QueueCap)
	}
}

func TestReporterDisabledByDefault(t *testing.T) {
	r := New(Config{}, PanelAuth{BaseURL: "https://p", Token: "t", NodeID: 1})
	if r.Enabled() {
		t.Fatal("expected disabled reporter with Enabled=false config")
	}
	// no-op must not panic
	r.Observe(1, "example.com", "1.1.1.1")
}

func TestReportAllQueuesMisses(t *testing.T) {
	// 无 httptest，直接验证入队逻辑：report_all=true 时未命中也入队
	r := New(Config{Enabled: false, ReportAll: true}, PanelAuth{})
	if r.Enabled() {
		t.Fatal("expected disabled (no auth)")
	}
	// 构造一个手动启用但不联网的 reporter
	r2 := &Reporter{cfg: Config{Enabled: true, ReportAll: true, QueueCap: 10}}
	r2.http = &http.Client{} // 仅作 Enabled() 判定，不实际请求
	r2.Observe(7, "miss.example.org", "1.1.1.1") // 无规则 → matched=false
	r2.mu.Lock()
	defer r2.mu.Unlock()
	if len(r2.queue) != 1 {
		t.Fatalf("expected 1 queued event (report_all), got %d", len(r2.queue))
	}
	if r2.queue[0].Matched {
		t.Error("expected Matched=false for non-matching target")
	}
	// report_all=false 时未命中不入队
	r3 := &Reporter{cfg: Config{Enabled: true, ReportAll: false, QueueCap: 10}}
	r3.http = &http.Client{}
	r3.Observe(7, "miss.example.org", "1.1.1.1")
	r3.mu.Lock()
	defer r3.mu.Unlock()
	if len(r3.queue) != 0 {
		t.Fatalf("expected 0 queued events (report_all=false), got %d", len(r3.queue))
	}
}

func TestReporterDisabledWithoutAuth(t *testing.T) {
	r := New(Config{Enabled: true}, PanelAuth{})
	if r.Enabled() {
		t.Fatal("expected disabled when panel auth missing")
	}
}

func TestReporterObserveAndFlush(t *testing.T) {
	var mu sync.Mutex
	var gotRulesAuth, gotReport map[string]interface{}
	var reported []Event

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		switch req.URL.Path {
		case rulesPath:
			gotRulesAuth = map[string]interface{}{
				"token":   req.URL.Query().Get("token"),
				"node_id": req.URL.Query().Get("node_id"),
			}
			w.Header().Set("Content-Type", "application/json")
			io.WriteString(w, `{"data":[{"id":1,"name":"t","match_type":"domain_suffix","match_value":"bad.com\nEVIL.org"}]}`)
		case reportPath:
			body, _ := io.ReadAll(req.Body)
			var payload struct {
				Token  string  `json:"token"`
				NodeID int     `json:"node_id"`
				Events []Event `json:"events"`
			}
			json.Unmarshal(body, &payload)
			gotReport = map[string]interface{}{"token": payload.Token, "node_id": payload.NodeID}
			reported = append(reported, payload.Events...)
			w.Header().Set("Content-Type", "application/json")
			io.WriteString(w, `{"data":{"received":1,"matched":1,"banned":0}}`)
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer srv.Close()

	r := New(Config{Enabled: true, FlushInterval: 1, RulesRefresh: 1},
		PanelAuth{BaseURL: srv.URL, Token: "tok123", NodeID: 7, NodeType: "shadowsocks"})
	if !r.Enabled() {
		t.Fatal("expected enabled reporter")
	}

	// wait for initial rule pull
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		r.mu.Lock()
		n := len(r.rules)
		r.mu.Unlock()
		if n > 0 {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}

	r.Observe(42, "sub.bad.com", "9.9.9.9")  // hit
	r.Observe(42, "good.com", "9.9.9.9")     // miss
	r.Observe(42, "a.evil.org", "")          // hit (case-insensitive rule value)
	r.Observe(0, "bad.com", "")              // invalid user

	// wait for flush
	deadline = time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		mu.Lock()
		n := len(reported)
		mu.Unlock()
		if n >= 2 {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}

	mu.Lock()
	defer mu.Unlock()
	if len(reported) != 2 {
		t.Fatalf("expected 2 reported events, got %d: %+v", len(reported), reported)
	}
	if reported[0].UserID != 42 || reported[0].Target != "sub.bad.com" || reported[0].SourceIP != "9.9.9.9" {
		t.Errorf("unexpected event[0]: %+v", reported[0])
	}
	// 认证必须复用节点 token/node_id
	if gotRulesAuth["token"] != "tok123" || gotRulesAuth["node_id"] != "7" {
		t.Errorf("rules auth wrong: %+v", gotRulesAuth)
	}
	if gotReport == nil || gotReport["token"] != "tok123" || gotReport["node_id"] != 7 {
		t.Errorf("report auth wrong: %+v", gotReport)
	}
}

func TestReporterRequeueOnFailure(t *testing.T) {
	var mu sync.Mutex
	fail := true
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		if req.URL.Path == rulesPath {
			io.WriteString(w, `{"data":[{"id":1,"name":"t","match_type":"domain","match_value":"x.com"}]}`)
			return
		}
		mu.Lock()
		f := fail
		mu.Unlock()
		if f {
			w.WriteHeader(http.StatusBadGateway)
			return
		}
		io.WriteString(w, `{"data":{"received":1,"matched":1,"banned":0}}`)
	}))
	defer srv.Close()

	r := New(Config{Enabled: true, FlushInterval: 1, RulesRefresh: 60},
		PanelAuth{BaseURL: srv.URL, Token: "t", NodeID: 1})

	// wait for rules
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		r.mu.Lock()
		n := len(r.rules)
		r.mu.Unlock()
		if n > 0 {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}

	r.Observe(1, "x.com", "")
	// first flush fails → requeue
	time.Sleep(1500 * time.Millisecond)
	r.mu.Lock()
	queued := len(r.queue)
	r.mu.Unlock()
	if queued != 1 {
		t.Fatalf("expected 1 requeued event, got %d", queued)
	}

	mu.Lock()
	fail = false
	mu.Unlock()
	deadline = time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		r.mu.Lock()
		queued = len(r.queue)
		r.mu.Unlock()
		if queued == 0 {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if queued != 0 {
		t.Fatal("expected queue drained after recovery")
	}
}

// TestObserveDropsWhenQueueFull 回归：队列满时必须丢弃并计数，
// 而不是静默丢弃——静默丢弃曾让 report_all 模式的背压完全不可见。
func TestObserveDropsWhenQueueFull(t *testing.T) {
	r := &Reporter{cfg: Config{Enabled: true, ReportAll: true, QueueCap: 3}}
	r.http = &http.Client{}

	for i := 0; i < 10; i++ {
		r.Observe(i+1, "miss.example.org", "1.1.1.1")
	}

	r.mu.Lock()
	queued := len(r.queue)
	r.mu.Unlock()
	if queued != 3 {
		t.Fatalf("queued = %d, want 3 (QueueCap)", queued)
	}
	if got := r.Stats().Dropped; got != 7 {
		t.Fatalf("Dropped = %d, want 7", got)
	}
}

// TestFlushAllDrainsMultipleBatches 回归：一次 flush 必须连续发送多批，
// 直到队列空。旧实现每个 tick 只发 BatchMax 条，report_all 下必然堆积到溢出。
func TestFlushAllDrainsMultipleBatches(t *testing.T) {
	var mu sync.Mutex
	var batches []int

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		if req.URL.Path == rulesPath {
			io.WriteString(w, `{"data":[]}`)
			return
		}
		body, _ := io.ReadAll(req.Body)
		var payload struct {
			Events []Event `json:"events"`
		}
		json.Unmarshal(body, &payload)
		mu.Lock()
		batches = append(batches, len(payload.Events))
		mu.Unlock()
		io.WriteString(w, `{"data":{"received":0,"matched":0,"banned":0}}`)
	}))
	defer srv.Close()

	r := New(Config{Enabled: true, ReportAll: true, BatchMax: 10, QueueCap: 1000, FlushInterval: 60, RulesRefresh: 60},
		PanelAuth{BaseURL: srv.URL, Token: "t", NodeID: 1})
	if !r.Enabled() {
		t.Fatal("expected enabled")
	}

	for i := 0; i < 45; i++ {
		r.Observe(i+1, "miss.example.org", "1.1.1.1")
	}

	r.flushAll()

	mu.Lock()
	defer mu.Unlock()
	// 45 条 / 每批 10 条 → 5 批，最后一批 5 条
	if len(batches) != 5 {
		t.Fatalf("expected 5 batches, got %d: %v", len(batches), batches)
	}
	total := 0
	for _, n := range batches {
		total += n
	}
	if total != 45 {
		t.Fatalf("expected 45 events delivered, got %d", total)
	}
	r.mu.Lock()
	left := len(r.queue)
	r.mu.Unlock()
	if left != 0 {
		t.Fatalf("queue not drained, %d left", left)
	}
}

// TestFlushAllStopsOnFailure 一批失败后必须立刻停止本 tick，
// 否则会在面板故障时打出 maxBatchesPerFlush 次无意义的失败请求。
func TestFlushAllStopsOnFailure(t *testing.T) {
	var mu sync.Mutex
	var posts int

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		if req.URL.Path == rulesPath {
			io.WriteString(w, `{"data":[]}`)
			return
		}
		mu.Lock()
		posts++
		mu.Unlock()
		w.WriteHeader(http.StatusBadGateway)
	}))
	defer srv.Close()

	r := New(Config{Enabled: true, ReportAll: true, BatchMax: 10, QueueCap: 1000, FlushInterval: 60, RulesRefresh: 60},
		PanelAuth{BaseURL: srv.URL, Token: "t", NodeID: 1})

	for i := 0; i < 45; i++ {
		r.Observe(i+1, "miss.example.org", "1.1.1.1")
	}
	r.flushAll()

	mu.Lock()
	got := posts
	mu.Unlock()
	if got != 1 {
		t.Fatalf("expected exactly 1 POST before bailing out, got %d", got)
	}
	if st := r.Stats(); st.Failed != 1 || st.Queued != 45 {
		t.Fatalf("stats = %+v, want Failed=1 Queued=45", st)
	}
}
