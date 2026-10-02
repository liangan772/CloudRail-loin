# frozen_string_literal: true

# name: discourse-geetest-captcha
# about: GeeTest CAPTCHA v4 (极验行为验证第四代) human verification for Discourse
# version: 1.0.0
# authors: liangan772
# url: https://github.com/liangan772/CloudRail-loin
# required_version: 3.2.0

enabled_site_setting :geetest_captcha_enabled

register_asset "stylesheets/common/geetest-captcha.scss"

after_initialize do
  # Make `lib/` autoloadable under the `Gt4` namespace, following
  # https://meta.discourse.org/t/256092 (Rails autoloading in plugins).
  Rails.autoloaders.main.push_dir(File.expand_path("../lib", __dir__), namespace: Gt4)

  require_relative "lib/gt4/client"
  require_relative "lib/gt4/verified_store"
  require_relative "lib/gt4/validator"
  require_relative "lib/gt4/controller_extension"
  require_relative "lib/gt4/guard"

  # The four fields produced by the GT4 front-end are not part of the
  # standard Discourse payload, so strong parameters would drop them.
  # `Discourse::ApplicationController.permitted` is the supported hook
  # for whitelisting extra params.
  Discourse::ApplicationController.include(Gt4::ControllerExtension)

  %i[signup session topic post].each do |controller_key|
    Gt4::ControllerExtension.permit_gt4_params(controller_key)
  end

  # Install the per-endpoint guards. Re-runs whenever site settings
  # change; `prepend_once` keeps it idempotent.
  Gt4::Guard.install!

  on(:site_setting_changed) do |_name, _old, _new|
    Gt4::Guard.install!
  end
end
