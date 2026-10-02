# frozen_string_literal: true

module ::Gt4
  # Lightweight counters for the admin dashboard.
  #
  # Every verified request lands in exactly one bucket:
  #
  #   pass     -> GeeTest confirmed the challenge
  #   fail     -> GeeTest rejected it
  #   degraded -> the GeeTest API was unreachable and we fell back to
  #               the fail-open / fail-closed policy
  #   missing  -> the client sent no (or partial) GT4 payload
  #
  # Counters are kept in Redis so they aggregate across processes, and
  # are bucketed per day so the dashboard can show a rolling window
  # without unbounded key growth.
  class Stats
    PREFIX = "gt4:stats:"
    BUCKETS = %w[pass fail degraded missing].freeze
    TTL = 90 * 24 * 60 * 60 # keep 90 days of daily buckets

    class << self
      def record(bucket)
        bucket = bucket.to_s
        return unless BUCKETS.include?(bucket)

        key = "#{PREFIX}#{Date.today.strftime("%Y%m%d")}:#{bucket}"
        Discourse.redis.incr(key)
        Discourse.redis.expire(key, TTL)
      rescue StandardError => e
        # Stats must never break the verification path.
        Rails.logger.warn("[geetest-captcha] failed to record stat #{bucket}: #{e.message}")
      end

      # Returns totals for the last `days` days (including today).
      #
      #   { "pass" => 120, "fail" => 3, "degraded" => 0, "missing" => 1,
      #     "total" => 124, "days" => 7 }
      def summary(days: 7)
        totals = BUCKETS.index_with(0)

        (0...days).each do |offset|
          date = (Date.today - offset).strftime("%Y%m%d")
          BUCKETS.each do |bucket|
            value = Discourse.redis.get("#{PREFIX}#{date}:#{bucket}")
            totals[bucket] += value.to_i
          end
        end

        totals["total"] = BUCKETS.sum { |bucket| totals[bucket] }
        totals["days"] = days
        totals
      end

      # Per-day breakdown, oldest first, for charting.
      def daily(days: 7)
        (days - 1).downto(0).map do |offset|
          date = Date.today - offset
          stamp = date.strftime("%Y%m%d")

          row = BUCKETS.index_with do |bucket|
            Discourse.redis.get("#{PREFIX}#{stamp}:#{bucket}").to_i
          end
          row["date"] = date.iso8601
          row
        end
      end

      def reset!
        cursor = "0"
        loop do
          cursor, keys = Discourse.redis.scan(cursor, match: "#{PREFIX}*", count: 200)
          Discourse.redis.del(*keys) if keys.any?
          break if cursor == "0"
        end
      end
    end
  end
end
