"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const source = fs.readFileSync(
  path.join(__dirname, "../container/autologin-extension/autologin.js"),
  "utf8"
);

function runCase(
  search,
  autofilled = true,
  hasRealSubmit = true,
  hasRemember = true,
  rememberChecked = false
) {
  let clicks = 0;
  let formQueries = 0;
  let queries = 0;
  let rememberClicks = 0;
  let now = 0;
  const storage = new Map();
  const submit = { click() { clicks += 1; } };
  const remember = {
    checked: rememberChecked,
    click() {
      rememberClicks += 1;
      this.checked = true;
    }
  };
  const form = {
    querySelector(selector) {
      formQueries += 1;
      const selectors = selector.split(",").map((item) => item.trim());
      if (hasRealSubmit && selectors.includes("a#login_submit.login-btn")) {
        return submit;
      }
      if (hasRemember && selector ===
          "input#rememberMe[type='checkbox'][name='rememberMe'][value='true']") {
        return remember;
      }
      return null;
    }
  };
  const password = {
    form,
    matches(selector) {
      assert.equal(selector, ":-webkit-autofill");
      return autofilled;
    }
  };
  const context = {
    URL,
    URLSearchParams,
    Date: { now() { now += 500; return now; } },
    location: {
      hostname: "ids-hit-edu-cn-s.hitsz.edu.cn",
      pathname: "/authserver/login",
      search
    },
    document: {
      querySelector(selector) {
        queries += 1;
        assert.equal(selector, "input[type='password']");
        return password;
      }
    },
    sessionStorage: {
      getItem(key) { return storage.get(key) || null; },
      setItem(key, value) { storage.set(key, value); }
    },
    setTimeout(callback) { callback(); }
  };

  vm.runInNewContext(source, context);
  return { clicks, formQueries, queries, rememberClicks };
}

const trustedService = new URLSearchParams({
  service: "https://trust.hitsz.edu.cn:443/passport/v1/auth/cas/?sfDomain=hitcas"
}).toString();
assert.deepEqual(runCase(`?${trustedService}`), {
  clicks: 1,
  formQueries: 6,
  queries: 3,
  rememberClicks: 1
});
const alreadyRemembered = runCase(`?${trustedService}`, true, true, true, true);
assert.equal(alreadyRemembered.clicks, 1);
assert.equal(alreadyRemembered.rememberClicks, 0);
const notAutofilled = runCase(`?${trustedService}`, false);
assert.equal(notAutofilled.clicks, 0);
assert.ok(notAutofilled.queries > 0);
const missingSubmit = runCase(`?${trustedService}`, true, false);
assert.equal(missingSubmit.clicks, 0);
assert.ok(missingSubmit.formQueries > 0);
const missingRemember = runCase(`?${trustedService}`, true, true, false);
assert.equal(missingRemember.clicks, 0);

const foreignService = new URLSearchParams({
  service: "https://example.com/passport/v1/auth/cas/?sfDomain=hitcas"
}).toString();
assert.deepEqual(runCase(`?${foreignService}`), {
  clicks: 0,
  formQueries: 0,
  queries: 0,
  rememberClicks: 0
});
assert.deepEqual(runCase(""), {
  clicks: 0,
  formQueries: 0,
  queries: 0,
  rememberClicks: 0
});

process.stdout.write("PASS: autologin service boundary\n");
