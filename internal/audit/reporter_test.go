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

func TestReporterDisabledByDefault(t *testing.T) {
	r := New(Config{}, PanelAuth{BaseURL: "https://p", Token: "t", NodeID: 1})
	if r.Enabled() {
		t.Fatal("expected disabled reporter with Enabled=false config")
	}
	// no-op must not panic
	r.Observe(1, "example.com", "1.1.1.1")
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
