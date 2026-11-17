# frozen_string_literal: true

# Run: ruby scripts/test_build_mihomo_config.rb
# Uses only the Ruby standard library, so no gems are needed.
require "yaml"
require_relative "build-mihomo-config"

# Minimal test runner: every test_* method runs with a fresh setup.
class TestCase
  Failure = Class.new(StandardError)

  def assert(value, message = "expected truthy value")
    raise Failure, message unless value
  end

  def refute(value, message = "expected falsy value")
    raise Failure, message if value
  end

  def assert_equal(expected, actual)
    assert expected == actual, "expected #{expected.inspect}, got #{actual.inspect}"
  end

  def assert_includes(collection, item)
    assert collection.include?(item), "expected #{item.inspect} in #{collection.inspect[0, 300]}"
  end

  def assert_empty(collection)
    assert collection.empty?, "expected empty, got #{collection.inspect}"
  end

  def assert_match(pattern, string)
    assert pattern.match?(string.to_s), "expected #{string.inspect} to match #{pattern.inspect}"
  end

  def self.run_all
    tests = instance_methods(false).grep(/\Atest_/).sort
    failures = tests.filter_map do |name|
      test = new
      test.setup
      test.public_send(name)
      nil
    rescue StandardError => e
      "#{name}: #{e.class}: #{e.message}"
    end
    puts failures
    puts "#{tests.length} tests, #{failures.length} failures"
    exit(failures.empty? ? 0 : 1)
  end
end

class BuildMihomoConfigTest < TestCase
  ROOT = File.expand_path("..", __dir__)
  SOURCE = File.read(File.join(ROOT, "Shadowrocket.conf"))

  def setup
    @yaml = MihomoConfig.build(SOURCE)
    @config = YAML.safe_load(@yaml)
    @groups = @config["proxy-groups"].to_h { |group| [group["name"], group] }
    @rules = @config["rules"]
  end

  def test_proxy_group_holds_every_subscription_node
    assert_equal({ "name" => "PROXY", "type" => "select", "use" => ["my-subscription"] }, @groups["PROXY"])
  end

  def test_default_policy_is_listed_first
    assert_equal "PROXY", @groups["🚀 节点选择"]["proxies"].first
    assert_equal "PROXY", @groups["📧 邮件服务"]["proxies"].first
    assert_equal "🇺🇸 美国节点", @groups["🤖 AI 服务"]["proxies"].first
    assert_equal "DIRECT", @groups["🏦 香港银行"]["proxies"].first
  end

  def test_region_filter_is_copied_verbatim
    assert_equal "🇯🇵|JP|Japan|japan|Tokyo|tokyo|日本|东京|大阪", @groups["🇯🇵 日本节点"]["filter"]
    assert @groups["🌐 其他节点"]["filter"].start_with?("^((?!(🇭🇰|HK|")
  end

  def test_empty_region_group_rejects_instead_of_going_direct
    assert_equal "REJECT", @groups["🇸🇬 新加坡节点"]["empty-fallback"]
    assert_equal 5000, @groups["🇸🇬 新加坡节点"]["timeout"]
  end

  def test_subscription_nodes_are_forced_to_claim_udp
    assert_equal({ "udp" => true }, @config.dig("proxy-providers", "my-subscription", "override"))
  end

  def test_quic_is_rejected_only_before_rules_that_default_to_a_proxy
    assert_includes @rules, "AND,((NETWORK,UDP),(DST-PORT,443),(RULE-SET,google)),REJECT"
    assert_includes @rules, "AND,((NETWORK,UDP),(DST-PORT,443),(DOMAIN,translate.googleapis.com)),REJECT"
    refute @rules.any? { |rule| rule.include?("(RULE-SET,china)") }
    assert_equal ["AND,((NETWORK,UDP),(DST-PORT,443)),REJECT", "MATCH,🐟 漏网之鱼"], @rules.last(2)
  end

  def test_protocol_condition_becomes_network
    assert_includes @rules, "AND,((NETWORK,TCP),(DST-PORT,5223)),🍎 苹果推送"
  end

  def test_skip_proxy_hosts_go_direct_and_get_real_ips
    assert_includes @rules, "DOMAIN-SUFFIX,icloud.com,DIRECT"
    assert_includes @rules, "DOMAIN,captive.apple.com,DIRECT"
    assert_includes @config.dig("dns", "fake-ip-filter"), "captive.apple.com"
    assert_includes @config.dig("dns", "fake-ip-filter"), "+.icloud.com"
  end

  def test_blackmatrix_sets_use_the_clash_format
    china = @config.dig("rule-providers", "china-domain")
    assert_equal "https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/China/China_Domain.yaml", china["url"]
    assert_equal %w[domain yaml], [china["behavior"], china["format"]]
    assert_equal "classical", @config.dig("rule-providers", "google", "behavior")
  end

  def test_dns_matches_shadowrocket
    dns = @config["dns"]
    assert_equal ["https://cloudflare-dns.com/dns-query#PROXY", "https://dns.google/dns-query#PROXY"], dns["nameserver"]
    assert_equal ["system"], dns["direct-nameserver"]
    assert_equal "system", dns.dig("nameserver-policy", "+.icloud.com")
    assert_equal "127.0.0.1", @config.dig("hosts", "localhost.weixin.qq.com")
  end

  def test_problems_is_empty_for_generated_config
    assert_empty MihomoConfig.problems(@yaml)
  end

  def test_problems_reports_unknown_policy
    broken = @yaml.sub("RULE-SET,mail,📧 邮件服务", "RULE-SET,mail,📧 邮件服务TYPO")
    assert_includes MihomoConfig.problems(broken), "unknown policy in: RULE-SET,mail,📧 邮件服务TYPO"
  end

  def test_problems_reports_shadowrocket_only_rule
    broken = @yaml.sub("MATCH,🐟 漏网之鱼", "FINAL,🐟 漏网之鱼")
    refute broken == @yaml, "fixture did not change the YAML"
    assert_includes MihomoConfig.problems(broken), "unsupported rule type: FINAL,🐟 漏网之鱼"
  end

  def test_problems_reports_invalid_yaml
    assert_match(/\Ainvalid YAML: /, MihomoConfig.problems("rules: [unclosed\n").first)
  end

  def test_committed_yaml_is_current
    assert_equal @yaml, File.read(File.join(ROOT, "Clash-Verge-Rev.yaml"))
  end
end

BuildMihomoConfigTest.run_all
