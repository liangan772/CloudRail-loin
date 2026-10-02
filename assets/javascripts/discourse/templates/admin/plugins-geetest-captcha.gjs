import GeetestCaptchaAdmin from "discourse/plugins/discourse-geetest-captcha/discourse/components/geetest-captcha-admin";

/**
 * Admin page body, mounted at /admin/plugins/geetest-captcha.
 *
 * Discourse resolves plugin admin templates from
 * `templates/admin/plugins-<route-name>.gjs`. The component below holds
 * all of the state and data loading, so this template is a single tag.
 */
<template>
  <GeetestCaptchaAdmin />
</template>
