# frozen_string_literal: true

module ::Gt4
  # Anti-replay guard for successfully validated challenges.
  #
  # GT4's `lot_number` is unique per verification round. Because the
  # client could otherwise replay the same set of parameters to our
  # endpoint more than once (e.g. double-click, scripted retry), we
  # remember every successfully consumed `lot_number` for a short TTL
  # and reject duplicates within that window.
  #
  # Backed by Discourse's `Discourse.redis`, so it works across a
  # multi-process / multi-host cluster without extra infrastructure.
  class VerifiedStore
    PREFIX = "gt4:lot:"
    # `pass_token` from GT4 is short-lived; 10 minutes is a safe window
    # that comfortably outlives any legitimate retry and avoids
    # unbounded key growth.
    TTL = 10 * 60

    class << self
      # Atomically claims a `lot_number`.
      #
      # Returns true  when the caller is the first to consume it.
      # Returns false when it was already consumed (replay).
      def claim(lot_number)
        return false if lot_number.to_s.empty?

        key = "#{PREFIX}#{lot_number}"
        # SET NX EX is atomic, so two concurrent requests can never
        # both receive `true`.
        result = Discourse.redis.set(key, "1", nx: true, ex: TTL)
        result == true || result == "OK"
      end

      # Releases a previously claimed lot_number. Used when the
      # downstream business check (e.g. wrong password) failed and the
      # user should be allowed to retry with the same challenge.
      def release(lot_number)
        return if lot_number.to_s.empty?

        Discourse.redis.del("#{PREFIX}#{lot_number}")
      end

      def claimed?(lot_number)
        return false if lot_number.to_s.empty?

        Discourse.redis.exists?("#{PREFIX}#{lot_number}")
      end
    end
  end
end
