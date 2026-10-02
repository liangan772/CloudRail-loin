# frozen_string_literal: true

# Single source of truth for every site setting the plugin owns.
#
# The admin dashboard needs three things for each setting:
#
#   1. how to *read* it (and whether the value may be shown verbatim),
#   2. how to *validate* a value coming back from the browser, and
#   3. how to *coerce* a JSON value into something `SiteSetting` accepts.
#
# Rather than scatter that knowledge across the controller, the template
# and the locale files, it lives here once. `config/settings.yml` remains
# authoritative for the *defaults*; this registry is authoritative for
# everything else, and a spec asserts the two stay in sync.
module ::Gt4
  module SettingsRegistry
    # `type` drives the form control in the admin UI:
    #
    #   :boolean — toggle
    #   :string  — plain text input
    #   :secret  — password input; blank means "leave unchanged"
    #   :enum    — <select> built from `choices`
    #
    # `masked` entries are never echoed back verbatim; only a fingerprint
    # plus a "is it set?" flag is returned, so a compromised admin session
    # (or a shoulder-surfer) cannot exfiltrate the value.
    DEFINITIONS = [
      {
        key: :geetest_captcha_enabled,
        type: :boolean,
        group: :basic,
        label: "enabled",
        client: true,
      },
      {
        key: :geetest_captcha_id,
        type: :string,
        group: :basic,
        label: "captcha_id",
        client: true,
        masked: true,
        required_when_enabled: true,
        # GeeTest ids are 32-char lowercase hex. Accept anything
        # hex-shaped so future id formats do not require a plugin update,
        # but reject obvious paste accidents (spaces, quotes, urls).
        pattern: /\A[0-9a-zA-Z]{8,64}\z/,
      },
      {
        key: :geetest_captcha_key,
        type: :secret,
        group: :basic,
        label: "captcha_key",
        required_when_enabled: true,
        # Blank means "keep the stored value". A non-blank value must be
        # hex-ish, same reasoning as the id.
        pattern: /\A[0-9a-zA-Z]{8,64}\z/,
      },
      {
        key: :geetest_captcha_api_server,
        type: :string,
        group: :advanced,
        label: "api_server",
        default: "gcaptcha4.geetest.com",
        # Hostname only — no scheme, no path, no port. The client
        # normalises a pasted URL, but we reject anything that is clearly
        # not a host so a broken config fails loudly here instead of
        # silently at verification time.
        pattern: /\A(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}\z/,
      },
      {
        key: :geetest_captcha_product,
        type: :enum,
        group: :basic,
        label: "product",
        client: true,
        choices: %w[bind popup float],
      },
      {
        key: :geetest_captcha_language,
        type: :enum,
        group: :basic,
        label: "language",
        client: true,
        choices: %w[zho eng zho-tw zho-hk jpn kor rus spa fra deu ara],
      },
      {
        key: :geetest_captcha_on_signup,
        type: :boolean,
        group: :scopes,
        label: "signup",
        client: true,
      },
      {
        key: :geetest_captcha_on_login,
        type: :boolean,
        group: :scopes,
        label: "login",
        client: true,
      },
      {
        key: :geetest_captcha_on_post,
        type: :boolean,
        group: :scopes,
        label: "post",
        client: true,
      },
      {
        key: :geetest_captcha_fail_open,
        type: :boolean,
        group: :advanced,
        label: "fail_open",
      },
      {
        key: :geetest_captcha_show_errors,
        type: :boolean,
        group: :advanced,
        label: "show_errors",
        client: true,
      },
    ].map(&:freeze).freeze

    GROUPS = %i[basic scopes advanced].freeze

    class << self
      def all
        DEFINITIONS
      end

      def keys
        DEFINITIONS.map { |d| d[:key] }
      end

      def groups
        GROUPS
      end

      def find(key)
        sym = key.to_s.to_sym
        DEFINITIONS.find { |d| d[:key] == sym }
      end

      # All settings belonging to a form section, in registry order.
      def for_group(group)
        sym = group.to_s.to_sym
        DEFINITIONS.select { |d| d[:group] == sym }
      end

      def masked?(key)
        find(key)&.fetch(:masked, false) || type_of(key) == :secret
      end

      def type_of(key)
        find(key)&.fetch(:type, :string) || :string
      end

      # ---------------------------------------------------------------- #
      #  Read                                                           #
      # ---------------------------------------------------------------- #

      # Current value of a setting, safe to hand to the browser.
      #
      # Secrets and masked values become:
      #   { value: "", set: true, masked: true, fingerprint: "abcd…wxyz" }
      # Everything else returns the raw coerced value under `value`.
      def read(key)
        definition = find(key)
        return nil unless definition

        raw = raw_value(definition[:key])

        if masked?(definition[:key])
          { value: "", set: present?(raw), masked: true, fingerprint: fingerprint(raw) }
        else
          { value: raw, set: present?(raw), masked: false }
        end
      end

      # The whole registry as an ordered hash keyed by setting name, which
      # is exactly the shape the `.gjs` form renders from.
      def read_all
        DEFINITIONS.each_with_object({}) do |definition, acc|
          acc[definition[:key]] = read(definition[:key]).merge(metadata(definition))
        end
      end

      def metadata(definition)
        {
          type: definition[:type],
          group: definition[:group],
          label: definition[:label],
          client: definition.fetch(:client, false),
          choices: definition[:choices],
          required: definition.fetch(:required_when_enabled, false),
        }.compact
      end

      # ---------------------------------------------------------------- #
      #  Write                                                          #
      # ---------------------------------------------------------------- #

      # Validate + coerce a hash of browser-supplied values.
      #
      # Returns `[updates, errors]`:
      #   updates — { setting_name => coerced_value } to persist
      #   errors  — { setting_name => [message, ...] }
      #
      # A blank `:secret` is *skipped*, not written, so the admin form can
      # be submitted without re-typing the captcha key.
      def build_updates(params)
        updates = {}
        errors = {}

        DEFINITIONS.each do |definition|
          key = definition[:key]
          next unless params.key?(key) || params.key?(key.to_s)

          raw = params[key] || params[key.to_s]
          coerced, error = coerce(definition, raw)

          if error
            errors[key] = Array(error)
            next
          end

          next if coerced == :skip

          updates[key] = coerced
        end

        cross_validate!(params, updates, errors)

        [updates, errors]
      end

      def apply!(updates)
        updates.each do |key, value|
          SiteSetting.public_send("#{key}=", value)
        end
      end

      # ---------------------------------------------------------------- #
      #  Internals                                                      #
      # ---------------------------------------------------------------- #

      private

      def raw_value(key)
        SiteSetting.public_send(key)
      rescue StandardError
        nil
      end

      def present?(value)
        !(value.nil? || value == false || value.to_s.strip.empty?)
      end

      def fingerprint(value)
        str = value.to_s
        return "" if str.empty?
        return "#{str[0, 4]}…" if str.length <= 8

        "#{str[0, 4]}…#{str[-4, 4]}"
      end

      # Returns `[value_or_:skip, nil]` on success or `[nil, errors]` on
      # failure. `:skip` means "this field was left alone".
      def coerce(definition, raw)
        case definition[:type]
        when :boolean
          [ActiveModel::Type::Boolean.new.cast(raw) || false, nil]

        when :enum
          value = raw.to_s.strip
          value = definition[:default].to_s if value.empty? && definition[:default]
          return [:skip, nil] if value.empty?
          return [nil, :invalid_choice] unless definition[:choices].include?(value)

          [value, nil]

        else # :string, :secret
          value = raw.to_s.strip

          # A blank secret is a deliberate no-op.
          return [:skip, nil] if value.empty? && definition[:type] == :secret

          # A blank optional string resets to the default.
          return [definition[:default].to_s, nil] if value.empty?

          if (pattern = definition[:pattern]) && !pattern.match?(value)
            return [nil, :invalid_format]
          end

          [value, nil]
        end
      rescue StandardError
        [nil, :invalid_format]
      end

      # Rules that span more than one setting.
      def cross_validate!(_params, updates, errors)
        # Turning the plugin on requires usable credentials. We only
        # complain when the admin is actually asking for it, so an
        # in-progress configuration can be saved.
        return unless truthy?(updates[:geetest_captcha_enabled])

        id = updates.fetch(:geetest_captcha_id, raw_value(:geetest_captcha_id))
        key = updates.fetch(:geetest_captcha_key, raw_value(:geetest_captcha_key))

        errors[:geetest_captcha_id] ||= [:required_when_enabled] unless present?(id)
        errors[:geetest_captcha_key] ||= [:required_when_enabled] unless present?(key)
      end

      def truthy?(value)
        value == true || value.to_s == "true"
      end
    end
  end
end
