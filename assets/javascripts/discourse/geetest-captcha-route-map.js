/**
 * Registers the plugin's admin route at /admin/plugins/geetest-captcha.
 *
 * Discourse maps this file by naming convention: a file called
 * `<plugin-name>-route-map.js` exporting a route map object is picked up
 * automatically and merged into the Ember router.
 */
export default {
  resource: "admin.adminPlugins",
  path: "/plugins",
  map() {
    this.route("geetest-captcha");
  },
};
