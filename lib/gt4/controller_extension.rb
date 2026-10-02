# frozen_string_literal: true

module ::Gt4
  # Adds the four GeeTest fields to Discourse's strong parameters and
  # provides `verify_geetest!` for controllers.
  #
  # Design notes:
  #
  # * Every constant lookup happens *inside* a method guarded by
  #   `defined?`, never at load time. A rake task (db:migrate, assets,
  #   etc.) must never be able to fail because a controller class has
  #   not been eager-loaded yet.
  #
  # * `Discourse::ApplicationController.permitted` is the supported hook
  #   for whitelisting extra params. If it is unavailable we fall back to
  #   patching the individual controllers' `permitted` parameters via
  #   `before_action`, which is what older releases require.
  module ControllerExtension
    GT4_FIELDS = %i[lot_number captcha_output pass_token gen_time].freeze

    # Controller keys whose `permitted` params should carry the GT4 fields.
    CONTROLLER_KEYS = %i[signup session topic post].freeze

    class << self
      # Idempotent installer. Safe to call many times.
      def install!
        permit_gt4_params
        Gt4::Guard.install!
      rescue StandardError => e
        Rails.logger.warn("[geetest-captcha] install! failed: #{e.class}: #{e.message}")
      end

      def permit_gt4_params
        app_controller = safe_const("Discourse::ApplicationController")
        return unless app_controller

        if app_controller.respond_to?(:permitted)
          CONTROLLER_KEYS.each do |key|
            app_controller.permitted(key, :params) do
              params.permit(*GT4_FIELDS)
            end
          end
        else
          # Older Discourse: no central hook, so allow the params on the
          # controllers that actually receive them.
          patch_controller_params
        end
      end

      # Resolves a namespaced constant, returning nil instead of raising
      # when any segment is missing.
      def safe_const(path)
        path.split("::").reject(&:empty?).reduce(Object) do |mod, name|
          return nil unless mod.is_a?(Module) && mod.const_defined?(name, false)

          mod.const_get(name, false)
        end
      end

      private

      def patch_controller_params
        {
          signup: "::SignupController",
          session: "::SessionController",
          post: "::PostsController",
        }.each do |_key, const_path|
          klass = safe_const(const_path)
          next unless klass

          prepend_param_module(klass)
        end
      end

      def prepend_param_module(klass)
        return if klass.ancestors.include?(Gt4ParamsPermitter)

        klass.prepend(Gt4ParamsPermitter)
      end
    end

    # Permits the GT4 fields for controllers that define their own
    # `permitted` parameter list.
    module Gt4ParamsPermitter
      def permitted
        base = super
        return base unless base.is_a?(ActionController::Parameters)

        base.permit(*Gt4::ControllerExtension::GT4_FIELDS)
      rescue StandardError
        super
      end
    end

    def self.included(base)
      base.helper_method(:geetest_enabled_for?) if base.respond_to?(:helper_method)
    end

    # Controller-level guard.
    #
    #   verify_geetest!(scope: :signup)
    #
    # Returns true when the request may proceed. On failure the response
    # is rendered here and the return value is false, so callers should
    # `return unless verify_geetest!(...)`.
    def verify_geetest!(scope:)
      return true unless Gt4::Validator.enabled_for?(scope)

      result = Gt4::Validator.verify(params, scope: scope)
      return true if result.ok?

      render_json_error(Gt4::Validator.error_message(result), status: 403)
      false
    end

    def geetest_enabled_for?(scope)
      Gt4::Validator.enabled_for?(scope)
    end

    # Releases a claimed challenge so the user can retry after a
    # business-level failure (e.g. wrong password).
    def release_geetest!
      Gt4::VerifiedStore.release(params[:lot_number].to_s)
    end
  end
end
