# frozen_string_literal: true

require "rails_helper"

RSpec.describe Gt4::Stats do
  before { Discourse.redis.flushdb }

  describe ".record" do
    it "increments the bucket for today" do
      described_class.record("pass")
      described_class.record("pass")
      described_class.record("fail")

      summary = described_class.summary(days: 1)
      expect(summary["pass"]).to eq(2)
      expect(summary["fail"]).to eq(1)
      expect(summary["total"]).to eq(3)
    end

    it "ignores unknown buckets" do
      described_class.record("bogus")

      expect(described_class.summary(days: 1)["total"]).to eq(0)
    end

    it "never raises on a Redis failure" do
      allow(Discourse.redis).to receive(:incr).and_raise(Redis::CannotConnectError)

      expect { described_class.record("pass") }.not_to raise_error
    end
  end

  describe ".summary" do
    it "aggregates across the requested window" do
      described_class.record("pass")

      # Simulate yesterday's traffic directly against Redis.
      yesterday = (Date.today - 1).strftime("%Y%m%d")
      Discourse.redis.set("#{described_class::PREFIX}#{yesterday}:pass", 5)

      expect(described_class.summary(days: 1)["pass"]).to eq(1)
      expect(described_class.summary(days: 2)["pass"]).to eq(6)
    end
  end

  describe ".daily" do
    it "returns one row per day, oldest first" do
      described_class.record("pass")

      rows = described_class.daily(days: 3)
      expect(rows.length).to eq(3)
      expect(rows.first["date"]).to eq((Date.today - 2).iso8601)
      expect(rows.last["pass"]).to eq(1)
    end
  end

  describe ".reset!" do
    it "clears all stat keys" do
      described_class.record("pass")
      described_class.reset!

      expect(described_class.summary(days: 1)["total"]).to eq(0)
    end
  end
end
