// Package audit implements the tx-node embedded access-audit reporter.
//
// tx-node = xboard-node + optional audit module. The module hooks sing-box
// kernel connections, matches targets against rules pulled from the panel
// (AccessAudit plugin), and reports hits back over the SAME node
// authentication channel as the stock reports (server token + node_id /
// machine token) — no separate credentials.
//
// Disabled by default: without an [audit] section in config.yml every public
// method is a no-op with zero overhead, and the binary behaves identically
// to stock xboard-node.
package audit

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/cedar2025/xboard-node/internal/nlog"
)

const (
	rulesPath  = "/api/v1/plugin/access-audit/rules"
	reportPath = "/api/v1/plugin/access-audit/report"
)

// Config mirrors the `audit:` section of config.yml.
type Config struct {
	// Enabled gates the whole module. Default false.
	Enabled bool `yaml:"enabled"`
	// ReportAll queues every routed connection (not just rule hits) so the
	// panel gets a full access log. Default false = only rule-matched hits.
	ReportAll bool `yaml:"report_all"`
	// BatchMax events per report POST. Default 50.
	BatchMax int `yaml:"batch_max"`
	// FlushInterval seconds between report attempts. Default 15.
	FlushInterval int `yaml:"flush_interval"`
	// RulesRefresh minutes between rule pulls. Default 5.
	RulesRefresh int `yaml:"rules_refresh"`
	// QueueCap bounds memory when the panel is unreachable. Default 5000.
	QueueCap int `yaml:"queue_cap"`
}

// PanelAuth carries the stock panel credentials so audit traffic is
// authenticated exactly like stock node reports (Xboard ServerV2 middleware:
// token + node_id, or machine_id + token + node_id).
type PanelAuth struct {
	BaseURL   string
	Token     string
	NodeID    int
	NodeType  string
	MachineID int
}

type rule struct {
	ID         int    `json:"id"`
	Name       string `json:"name"`
	MatchType  string `json:"match_type"`
	MatchValue string `json:"match_value"`

	values []string // preprocessed (lowercased, split by newline/comma)
}

// Event is one audit hit. JSON shape matches the panel report API.
type Event struct {
	UserID   int    `json:"user_id"`
	Target   string `json:"target"`
	SourceIP string `json:"source_ip,omitempty"`
	Matched  bool   `json:"matched"` // 是否命中审计规则（report_all 模式下区分全量/命中）
}

// Reporter pulls rules, matches connection targets and batches reports.
// Safe for concurrent use. A nil *Reporter is valid and disabled.
type Reporter struct {
	auth PanelAuth
	cfg  Config

	http *http.Client

	mu    sync.Mutex
	rules []rule
	queue []Event
}

// New builds a Reporter. Returns a disabled (but non-nil) reporter when
// cfg.Enabled is false or the panel auth is incomplete.
func New(cfg Config, auth PanelAuth) *Reporter {
	r := &Reporter{cfg: cfg, auth: auth}
	if !cfg.Enabled {
		return r
	}
	if auth.BaseURL == "" || auth.Token == "" {
		nlog.Core().Warn("audit: enabled but panel url/token missing, disabled")
		return r
	}
	if cfg.BatchMax <= 0 {
		cfg.BatchMax = 50
	}
	if cfg.FlushInterval <= 0 {
		cfg.FlushInterval = 15
	}
	if cfg.RulesRefresh <= 0 {
		cfg.RulesRefresh = 5
	}
	if cfg.QueueCap <= 0 {
		cfg.QueueCap = 5000
	}
	// report_all 量级大得多，放宽批量和队列默认上限
	if cfg.ReportAll {
		if cfg.BatchMax <= 0 || cfg.BatchMax == 50 {
			cfg.BatchMax = 200
		}
		if cfg.QueueCap <= 0 || cfg.QueueCap == 5000 {
			cfg.QueueCap = 50000
		}
	}
	r.cfg = cfg
	r.auth.BaseURL = strings.TrimRight(auth.BaseURL, "/")
	r.http = &http.Client{Timeout: 15 * time.Second}

	go r.loop()
	nlog.Core().Info("audit reporter enabled",
		"panel", r.auth.BaseURL, "node_id", auth.NodeID, "machine_id", auth.MachineID)
	return r
}

// Enabled reports whether the module is active.
func (r *Reporter) Enabled() bool { return r != nil && r.http != nil }

// Observe is called by the kernel for every routed connection.
// report_all=false: only rule-matched targets are queued.
// report_all=true: every connection is queued, with Matched marking rule hits.
func (r *Reporter) Observe(userID int, target, sourceIP string) {
	if !r.Enabled() || userID <= 0 || target == "" {
		return
	}
	target = strings.ToLower(strings.TrimSpace(target))
	if target == "" {
		return
	}
	matched := r.match(target)
	if !matched && !r.cfg.ReportAll {
		return
	}
	r.mu.Lock()
	if len(r.queue) < r.cfg.QueueCap {
		r.queue = append(r.queue, Event{UserID: userID, Target: target, SourceIP: sourceIP, Matched: matched})
	}
	r.mu.Unlock()
}

// loop periodically refreshes rules and flushes the queue.
func (r *Reporter) loop() {
	r.refreshRules()
	refresh := time.NewTicker(time.Duration(r.cfg.RulesRefresh) * time.Minute)
	flush := time.NewTicker(time.Duration(r.cfg.FlushInterval) * time.Second)
	defer refresh.Stop()
	defer flush.Stop()
	for {
		select {
		case <-refresh.C:
			r.refreshRules()
		case <-flush.C:
			r.flush()
		}
	}
}

// authQuery replicates panel.Client.authQuery for GET requests.
func (r *Reporter) authQuery() url.Values {
	q := url.Values{}
	q.Set("token", r.auth.Token)
	if r.auth.MachineID > 0 {
		q.Set("machine_id", strconv.Itoa(r.auth.MachineID))
	}
	if r.auth.NodeID > 0 {
		q.Set("node_id", strconv.Itoa(r.auth.NodeID))
	}
	if r.auth.NodeType != "" && r.auth.MachineID == 0 {
		q.Set("node_type", r.auth.NodeType)
	}
	return q
}

// authPayload replicates panel.Client.injectAuth for POST requests.
func (r *Reporter) authPayload(m map[string]interface{}) {
	m["token"] = r.auth.Token
	if r.auth.MachineID > 0 {
		m["machine_id"] = r.auth.MachineID
	}
	if r.auth.NodeID > 0 {
		m["node_id"] = r.auth.NodeID
	}
	if r.auth.NodeType != "" && r.auth.MachineID == 0 {
		m["node_type"] = r.auth.NodeType
	}
}

// refreshRules pulls enabled rules from the panel.
func (r *Reporter) refreshRules() {
	req, err := http.NewRequest(http.MethodGet,
		r.auth.BaseURL+rulesPath+"?"+r.authQuery().Encode(), nil)
	if err != nil {
		return
	}
	resp, err := r.http.Do(req)
	if err != nil {
		nlog.Core().Warn("audit: refresh rules failed", "error", err)
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		nlog.Core().Warn("audit: refresh rules status", "status", resp.StatusCode)
		return
	}
	var body struct {
		Data []rule `json:"data"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&body); err != nil {
		return
	}
	for i := range body.Data {
		var vals []string
		for _, v := range strings.FieldsFunc(body.Data[i].MatchValue, func(c rune) bool {
			return c == '\n' || c == '\r' || c == ','
		}) {
			if v = strings.ToLower(strings.TrimSpace(v)); v != "" {
				vals = append(vals, v)
			}
		}
		body.Data[i].values = vals
	}
	r.mu.Lock()
	r.rules = body.Data
	r.mu.Unlock()
	nlog.Core().Debug("audit: rules refreshed", "count", len(body.Data))
}

// match checks target against cached rules. Semantics mirror the panel's
// PHP RuleMatcher.
func (r *Reporter) match(target string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	isIP := net.ParseIP(target) != nil
	for i := range r.rules {
		rule := &r.rules[i]
		if isIP && rule.MatchType != "ip_cidr" && rule.MatchType != "keyword" {
			continue
		}
		for _, v := range rule.values {
			if matchOne(rule.MatchType, v, target) {
				return true
			}
		}
	}
	return false
}

func matchOne(matchType, value, target string) bool {
	switch matchType {
	case "domain":
		return target == value
	case "domain_suffix":
		return target == value || strings.HasSuffix(target, "."+value)
	case "keyword":
		return strings.Contains(target, value)
	case "ip_cidr":
		return ipInCIDR(target, value)
	}
	return false
}

func ipInCIDR(ip, cidr string) bool {
	parsed := net.ParseIP(ip)
	if parsed == nil {
		return false
	}
	if !strings.Contains(cidr, "/") {
		return ip == cidr
	}
	_, network, err := net.ParseCIDR(cidr)
	if err != nil {
		return false
	}
	return network.Contains(parsed)
}

// flush posts up to BatchMax queued events; on failure the batch is
// requeued (bounded by QueueCap).
func (r *Reporter) flush() {
	r.mu.Lock()
	if len(r.queue) == 0 {
		r.mu.Unlock()
		return
	}
	batch := r.queue
	if len(batch) > r.cfg.BatchMax {
		batch = batch[:r.cfg.BatchMax]
	}
	r.queue = r.queue[len(batch):]
	r.mu.Unlock()

	payload := map[string]interface{}{"events": batch}
	r.authPayload(payload)
	body, _ := json.Marshal(payload)

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		r.auth.BaseURL+reportPath, bytes.NewReader(body))
	if err != nil {
		return
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := r.http.Do(req)
	if err != nil || resp.StatusCode != http.StatusOK {
		status := 0
		if resp != nil {
			status = resp.StatusCode
			io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))
			resp.Body.Close()
		}
		nlog.Core().Warn("audit: report failed, requeue",
			"error", err, "status", status, "events", len(batch))
		r.mu.Lock()
		if len(r.queue)+len(batch) <= r.cfg.QueueCap {
			r.queue = append(batch, r.queue...)
		}
		r.mu.Unlock()
		return
	}
	io.Copy(io.Discard, resp.Body)
	resp.Body.Close()
	nlog.Core().Debug("audit: reported", "events", len(batch))
}

// String implements fmt.Stringer without leaking the token.
func (r *Reporter) String() string {
	if !r.Enabled() {
		return "audit: disabled"
	}
	return fmt.Sprintf("audit: panel=%s node=%d queued=%d rules=%d",
		r.auth.BaseURL, r.auth.NodeID, len(r.queue), len(r.rules))
}
