# frozen_string_literal: true

require "rails_helper"

RSpec.describe Gt4::AdminController do
  fab!(:admin)
  fab!(:user)

  before do
    SiteSetting.geetest_captcha_enabled = true
    SiteSetting.geetest_captcha_id = "647f5ed2ed8acb4be36784e01556bb71"
    SiteSetting.geetest_captcha_key = "b09a7aafbfd83f73b35a9b530d0337bf"
    Discourse.redis.flushdb
  end

  describe "#status" do
    it "requires an admin" do
      sign_in(user)
      get "/admin/plugins/geetest-captcha/status.json"
      expect(response.status).to eq(404)
    end

    it "returns the configuration summary for an admin" do
      sign_in(admin)
      get "/admin/plugins/geetest-captcha/status.json"

      expect(response.status).to eq(200)
      json = response.parsed_body

      expect(json["enabled"]).to eq(true)
      expect(json["configured"]).to eq(true)
      expect(json["captcha_key_set"]).to eq(true)
      expect(json["scopes"]).to include(
        "signup" => true,
        "login" => false,
        "post" => false,
      )
      expect(json["health"]["ok"]).to eq(true)
    end

    it "never returns the raw captcha_id" do
      sign_in(admin)
      get "/admin/plugins/geetest-captcha/status.json"

      expect(response.parsed_body["captcha_id"]).not_to eq(
        SiteSetting.geetest_captcha_id,
      )
      expect(response.parsed_body["captcha_id"]).to include("…")
    end
  end

  describe "#stats" do
    it "returns the summary and daily breakdown" do
      Gt4::Stats.record("pass")
      Gt4::Stats.record("fail")

      sign_in(admin)
      get "/admin/plugins/geetest-captcha/stats.json", params: { days: 7 }

      expect(response.status).to eq(200)
      json = response.parsed_body

      expect(json["summary"]["pass"]).to eq(1)
      expect(json["summary"]["fail"]).to eq(1)
      expect(json["daily"].length).to eq(7)
    end

    it "clamps out-of-range day windows" do
      sign_in(admin)
      get "/admin/plugins/geetest-captcha/stats.json", params: { days: 500 }

      expect(response.parsed_body["days"]).to eq(7)
    end
  end

  describe "#reset_stats" do
    it "clears the counters" do
      Gt4::Stats.record("pass")

      sign_in(admin)
      delete "/admin/plugins/geetest-captcha/stats.json"

      expect(response.status).to eq(200)
      expect(Gt4::Stats.summary(days: 1)["total"]).to eq(0)
    end
  end

  describe "#toggle" do
    it "flips a scenario switch" do
      sign_in(admin)
      put "/admin/plugins/geetest-captcha/toggle.json", params: { scope: "login", value: true }

      expect(response.status).to eq(200)
      expect(SiteSetting.geetest_captcha_on_login).to eq(true)
    end

    it "rejects an unknown scope" do
      sign_in(admin)
      put "/admin/plugins/geetest-captcha/toggle.json", params: { scope: "nope", value: true }

      expect(response.status).to eq(400)
    end
  end

  describe "#test" do
    it "reports the connectivity result" do
      allow(Gt4::ConnectivityTest).to receive(:run).and_return(
        Gt4::ConnectivityTest::Result.new(
          reachable: true,
          latency_ms: 42,
          detail: "ok",
        ),
      )

      sign_in(admin)
      post "/admin/plugins/geetest-captcha/test.json"

      expect(response.status).to eq(200)
      expect(response.parsed_body["result"]).to include(
        "reachable" => true,
        "latency_ms" => 42,
      )
    end
  end
end
