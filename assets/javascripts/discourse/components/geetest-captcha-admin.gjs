import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { i18n } from "discourse-i18n";

const BASE = "/admin/plugins/geetest-captcha";

/**
 * Admin dashboard body for the GeeTest CAPTCHA v4 plugin.
 *
 * Authored as a `.gjs` single-file component: the template is inline in
 * `<template>` and every helper is imported explicitly. This is the
 * forward-looking format Discourse is migrating to, and the direct
 * replacement for the deprecated `.hbs` theme/plugin template extension
 * (https://meta.discourse.org/t/398896).
 *
 * The component owns all of its data loading, so the thin route
 * template can render it with a single tag.
 */
export default class GeetestCaptchaAdmin extends Component {
  @service dialog;

  @tracked loading = true;
  @tracked status = null;
  @tracked stats = null;
  @tracked statDays = 7;
  @tracked testing = false;
  @tracked testResult = null;
  @tracked busyScope = null;

  constructor() {
    super(...arguments);
    this.load();
  }

  get healthOk() {
    return Boolean(this.status?.health?.ok);
  }

  get checks() {
    return this.status?.health?.checks || [];
  }

  get scopes() {
    const scopes = this.status?.scopes || {};
    return [
      { key: "signup", enabled: scopes.signup },
      { key: "login", enabled: scopes.login },
      { key: "post", enabled: scopes.post },
    ];
  }

  get detailRows() {
    if (!this.status) {
      return [];
    }

    const label = (key) => i18n(`geetest_captcha.admin.detail.${key}`);
    const yesNo = (value) =>
      value
        ? i18n("geetest_captcha.admin.values.yes")
        : i18n("geetest_captcha.admin.values.no");

    return [
      { label: label("enabled"), value: this.onOff(this.status.enabled) },
      { label: label("captcha_id"), value: this.status.captcha_id || "—" },
      { label: label("captcha_key"), value: yesNo(this.status.captcha_key_set) },
      { label: label("api_server"), value: this.status.api_server || "—" },
      { label: label("product"), value: this.status.product || "—" },
      { label: label("language"), value: this.status.language || "—" },
      { label: label("fail_open"), value: this.onOff(this.status.fail_open) },
      { label: label("show_errors"), value: this.onOff(this.status.show_errors) },
    ];
  }

  get statCards() {
    const summary = this.stats?.summary || {};
    return ["pass", "fail", "degraded", "missing", "total"].map((key) => ({
      key,
      label: i18n(`geetest_captcha.admin.stats.${key}`),
      value: summary[key] ?? 0,
    }));
  }

  get hasStats() {
    return (this.stats?.summary?.total || 0) > 0;
  }

  get dayOptions() {
    return [1, 7, 30];
  }

  onOff(value) {
    return value
      ? i18n("geetest_captcha.admin.values.on")
      : i18n("geetest_captcha.admin.values.off");
  }

  @action
  async load() {
    this.loading = true;
    try {
      this.status = await ajax(`${BASE}/status`);
    } catch (e) {
      popupAjaxError(e);
    } finally {
      this.loading = false;
    }
    await this.loadStats();
  }

  @action
  async loadStats() {
    try {
      this.stats = await ajax(`${BASE}/stats?days=${this.statDays}`);
    } catch {
      // Statistics are non-critical: keep the rest of the page usable.
      this.stats = null;
    }
  }

  @action
  async changeDays(days) {
    this.statDays = days;
    await this.loadStats();
  }

  @action
  async runTest() {
    this.testing = true;
    this.testResult = null;
    try {
      const response = await ajax(`${BASE}/test`, { type: "POST" });
      this.testResult = response.result;
    } catch (e) {
      popupAjaxError(e);
    } finally {
      this.testing = false;
    }
  }

  @action
  async toggleScope(key) {
    const scope = this.scopes.find((item) => item.key === key);
    if (!scope) {
      return;
    }

    this.busyScope = key;
    try {
      await ajax(`${BASE}/toggle`, {
        type: "PUT",
        data: { scope: key, value: !scope.enabled },
      });
      await this.load();
    } catch (e) {
      popupAjaxError(e);
    } finally {
      this.busyScope = null;
    }
  }

  @action
  async toggleEnabled() {
    this.busyScope = "enabled";
    try {
      await ajax(`${BASE}/toggle`, {
        type: "PUT",
        data: { scope: "enabled", value: !this.status.enabled },
      });
      await this.load();
    } catch (e) {
      popupAjaxError(e);
    } finally {
      this.busyScope = null;
    }
  }

  @action
  async resetStats() {
    try {
      await this.dialog.yesNoConfirm({
        message: i18n("geetest_captcha.admin.stats.reset_confirm"),
      });
    } catch {
      return; // cancelled
    }

    try {
      await ajax(`${BASE}/stats`, { type: "DELETE" });
      await this.loadStats();
    } catch (e) {
      popupAjaxError(e);
    }
  }

  <template>
    <div class="gt4-admin">
      <div class="gt4-admin__header">
        <div>
          <h2>{{i18n "geetest_captcha.admin.title"}}</h2>
          <p class="gt4-admin__subtitle">{{i18n "geetest_captcha.admin.subtitle"}}</p>
        </div>
        <DButton
          @label="geetest_captcha.admin.refresh"
          @icon="sync"
          @action={{this.load}}
          class="btn-default"
        />
      </div>

      {{#if this.loading}}
        <div class="gt4-admin__loading">{{i18n "geetest_captcha.admin.loading"}}</div>
      {{else if this.status}}
        <section class="gt4-admin__card">
          <h3>{{i18n "geetest_captcha.admin.sections.health"}}</h3>
          <div class="gt4-admin__health {{if this.healthOk 'is-ok' 'is-bad'}}">
            <span class="gt4-admin__dot"></span>
            {{#if this.healthOk}}
              {{i18n "geetest_captcha.admin.health_ok"}}
            {{else}}
              {{i18n "geetest_captcha.admin.health_bad"}}
            {{/if}}
          </div>
          <ul class="gt4-admin__checks">
            {{#each this.checks as |check|}}
              <li class={{if check.ok "is-ok" "is-bad"}}>
                <span class="gt4-admin__check-icon">{{if check.ok "✓" "✕"}}</span>
                {{check.label}}
              </li>
            {{/each}}
          </ul>
        </section>

        <section class="gt4-admin__card">
          <h3>{{i18n "geetest_captcha.admin.sections.scopes"}}</h3>

          <div class="gt4-admin__switch-row">
            <span class="gt4-admin__switch-label">
              {{i18n "geetest_captcha.admin.detail.enabled"}}
            </span>
            <DButton
              @label={{if
                this.status.enabled
                "geetest_captcha.admin.values.on"
                "geetest_captcha.admin.values.off"
              }}
              @action={{this.toggleEnabled}}
              @disabled={{eq this.busyScope "enabled"}}
              class="btn-small {{if this.status.enabled 'btn-primary' 'btn-default'}}"
            />
          </div>

          {{#each this.scopes as |scope|}}
            <div class="gt4-admin__switch-row">
              <span class="gt4-admin__switch-label">
                {{i18n (concat "geetest_captcha.admin.scopes." scope.key)}}
              </span>
              <DButton
                @label={{if
                  scope.enabled
                  "geetest_captcha.admin.values.on"
                  "geetest_captcha.admin.values.off"
                }}
                @action={{fn this.toggleScope scope.key}}
                @disabled={{eq this.busyScope scope.key}}
                class="btn-small {{if scope.enabled 'btn-primary' 'btn-default'}}"
              />
            </div>
          {{/each}}
        </section>

        <section class="gt4-admin__card">
          <h3>{{i18n "geetest_captcha.admin.sections.detail"}}</h3>
          <table class="gt4-admin__table">
            <tbody>
              {{#each this.detailRows as |row|}}
                <tr>
                  <th>{{row.label}}</th>
                  <td>{{row.value}}</td>
                </tr>
              {{/each}}
            </tbody>
          </table>
        </section>

        <section class="gt4-admin__card">
          <h3>{{i18n "geetest_captcha.admin.sections.test"}}</h3>
          <DButton
            @label={{if
              this.testing
              "geetest_captcha.admin.test.running"
              "geetest_captcha.admin.test.run"
            }}
            @action={{this.runTest}}
            @disabled={{this.testing}}
            class="btn-default"
          />
          {{#if this.testResult}}
            <div
              class="gt4-admin__test-result {{if
                this.testResult.reachable
                'is-ok'
                'is-bad'
              }}"
            >
              {{#if this.testResult.reachable}}
                {{i18n
                  "geetest_captcha.admin.test.reachable"
                  ms=this.testResult.latency_ms
                }}
              {{else}}
                {{i18n "geetest_captcha.admin.test.unreachable"}}
              {{/if}}
              <div class="gt4-admin__test-detail">{{this.testResult.detail}}</div>
            </div>
          {{/if}}
        </section>

        <section class="gt4-admin__card">
          <div class="gt4-admin__card-head">
            <h3>{{i18n "geetest_captcha.admin.sections.stats"}}</h3>
            <div class="gt4-admin__range">
              {{#each this.dayOptions as |days|}}
                <DButton
                  @label={{concat days ""}}
                  @action={{fn this.changeDays days}}
                  class="btn-small {{if
                    (eq this.statDays days)
                    'btn-primary'
                    'btn-default'
                  }}"
                />
              {{/each}}
            </div>
          </div>

          <div class="gt4-admin__stat-grid">
            {{#each this.statCards as |card|}}
              <div class="gt4-admin__stat gt4-admin__stat--{{card.key}}">
                <div class="gt4-admin__stat-value">{{card.value}}</div>
                <div class="gt4-admin__stat-label">{{card.label}}</div>
              </div>
            {{/each}}
          </div>

          {{#unless this.hasStats}}
            <p class="gt4-admin__empty">{{i18n "geetest_captcha.admin.stats.empty"}}</p>
          {{/unless}}

          <DButton
            @label="geetest_captcha.admin.stats.reset"
            @action={{this.resetStats}}
            class="btn-danger btn-small"
          />
        </section>
      {{/if}}
    </div>
  </template>
}
