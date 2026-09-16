<?php

namespace Plugin\AccessAudit\Services;

use Plugin\AccessAudit\Models\AuditRule;

/**
 * 目标匹配引擎：域名/后缀/关键字/IP CIDR
 */
class RuleMatcher
{
    /** @var array<int, array{rule: AuditRule, values: string[]}> */
    private array $rules = [];

    public function __construct()
    {
        foreach (AuditRule::query()->where('enabled', 1)->get() as $rule) {
            $values = array_values(array_filter(array_map(
                fn ($v) => strtolower(trim($v)),
                preg_split('/[\r\n,]+/', (string) $rule->match_value)
            )));
            if ($values) {
                $this->rules[] = ['rule' => $rule, 'values' => $values];
            }
        }
    }

    /**
     * 返回命中的第一条规则，未命中返回 null
     */
    public function match(string $target): ?AuditRule
    {
        $target = strtolower(trim($target));
        if ($target === '') {
            return null;
        }

        $isIp = filter_var($target, FILTER_VALIDATE_IP) !== false;

        foreach ($this->rules as $entry) {
            $rule = $entry['rule'];
            // IP 目标只匹配 ip_cidr 和精确 keyword 规则，避免域名规则误伤
            if ($isIp && !in_array($rule->match_type, ['ip_cidr', 'keyword'], true)) {
                continue;
            }
            foreach ($entry['values'] as $value) {
                if ($this->matchOne($rule->match_type, $value, $target)) {
                    return $rule;
                }
            }
        }
        return null;
    }

    private function matchOne(string $type, string $value, string $target): bool
    {
        switch ($type) {
            case 'domain':
                return $target === $value;
            case 'domain_suffix':
                return $target === $value || str_ends_with($target, '.' . $value);
            case 'keyword':
                return str_contains($target, $value);
            case 'ip_cidr':
                return $this->ipInCidr($target, $value);
        }
        return false;
    }

    private function ipInCidr(string $ip, string $cidr): bool
    {
        if (!str_contains($cidr, '/')) {
            return $ip === $cidr;
        }
        [$subnet, $bits] = explode('/', $cidr, 2);
        $bits = (int) $bits;

        $ipBin = @inet_pton($ip);
        $subnetBin = @inet_pton($subnet);
        if ($ipBin === false || $subnetBin === false || strlen($ipBin) !== strlen($subnetBin)) {
            return false;
        }

        $bytes = intdiv($bits, 8);
        $rem = $bits % 8;
        if ($bytes > 0 && substr($ipBin, 0, $bytes) !== substr($subnetBin, 0, $bytes)) {
            return false;
        }
        if ($rem > 0) {
            $mask = (0xFF << (8 - $rem)) & 0xFF;
            return (ord($ipBin[$bytes]) & $mask) === (ord($subnetBin[$bytes]) & $mask);
        }
        return true;
    }
}
