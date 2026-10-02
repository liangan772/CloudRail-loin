# frozen_string_literal: true

# name: discourse-geetest-captcha
# about: GeeTest CAPTCHA v4 (极验行为验证第四代) human verification for Discourse
# version: 1.1.0
# authors: liangan772
# url: https://github.com/liangan772/CloudRail-loin
# required_version: 3.2.0

enabled_site_setting :geetest_captcha_enabled

register_asset "stylesheets/common/geetest-captcha.scss"
register_asset "stylesheets/admin/geetest-captcha-admin.scss"

# Adds a "GeeTest" entry to the admin Plugins page and wires the
# client-side route map (geetest-captcha-route-map.js) to a real
# server-rendered route so deep links work.
add_admin_route "geetest_captcha.admin.nav_label", "geetest-captcha"

after_initialize do
  # Make `lib/` autoloadable under the `Gt4` namespace, following
  # https://meta.discourse.org/t/256092 (Rails autoloading in plugins).
  Rails.autoloaders.main.push_dir(File.expand_path("../lib", __dir__), namespace: Gt4)

  require_relative "lib/gt4/client"
  require_relative "lib/gt4/verified_store"
  require_relative "lib/gt4/stats"
  require_relative "lib/gt4/validator"
  require_relative "lib/gt4/connectivity_test"
  require_relative "lib/gt4/controller_extension"
  require_relative "lib/gt4/guard"
  require_relative "lib/gt4/admin_controller"

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

  # ---------------------------------------------------------------- #
  #  Admin dashboard routes                                          #
  # ---------------------------------------------------------------- #
  Discourse::Application.routes.append do
    # Server-rendered shell for the client-side admin route, so that
    # visiting /admin/plugins/geetest-captcha directly still works.
    get "/admin/plugins/geetest-captcha" =>
          "admin/plugins#index",
        :constraints => StaffConstraint.new

    get "/admin/plugins/geetest-captcha/status" =>
          "gt4/admin#status",
        :constraints => StaffConstraint.new
    get "/admin/plugins/geetest-captcha/stats" =>
          "gt4/admin#stats",
        :constraints => StaffConstraint.new
    delete "/admin/plugins/geetest-captcha/stats" =>
             "gt4/admin#reset_stats",
           :constraints => StaffConstraint.new
    post "/admin/plugins/geetest-captcha/test" =>
           "gt4/admin#test",
         :constraints => StaffConstraint.new
    put "/admin/plugins/geetest-captcha/toggle" =>
          "gt4/admin#toggle",
        :constraints => StaffConstraint.new
  end
end
