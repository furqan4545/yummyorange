/* Website analytics: PostHog (US cloud), organization "YummyOrange", project 773695.
   Page views and page leaves, every click (autocapture, with rage and dead clicks), heatmaps, web analytics and
   session replay with every form field masked. Only on yummyorange.com: a local copy or a preview sends nothing.
   The app itself has no analytics. The privacy page (privacy.html › This website) describes all of this; keep it in
   step with any change here. The key below is PostHog's public project key, made to be embedded in web pages. */
(() => {
  'use strict';
  if (!/(^|\.)yummyorange\.com$/.test(location.hostname)) return;

  // PostHog's loader stub (from the project's own HTML snippet): queues calls until array.js has loaded.
  !function(t,e){var o,n,p,r;e.__SV||(window.posthog&&window.posthog.__loaded)||(window.posthog=e,e._i=[],e.init=function(i,s,a){function g(t,e){var o=e.split(".");2==o.length&&(t=t[o[0]],e=o[1]),t[e]=function(){t.push([e].concat(Array.prototype.slice.call(arguments,0)))}}(p=t.createElement("script")).type="text/javascript",p.crossOrigin="anonymous",p.async=!0,p.src=s.api_host.replace(".i.posthog.com","-assets.i.posthog.com")+"/static/array.js",(r=t.getElementsByTagName("script")[0]).parentNode.insertBefore(p,r);var u=e;for(void 0!==a?u=e[a]=[]:a="posthog",u.people=u.people||[],u.toString=function(t){var e="posthog";return"posthog"!==a&&(e+="."+a),t||(e+=" (stub)"),e},u.people.toString=function(){return u.toString(1)+".people (stub)"},o="init capture register register_once register_for_session unregister unregister_for_session getFeatureFlag getFeatureFlagPayload isFeatureEnabled reloadFeatureFlags updateEarlyAccessFeatureEnrollment getEarlyAccessFeatures on onFeatureFlags onSurveysLoaded onSessionId getSurveys getActiveMatchingSurveys renderSurvey canRenderSurvey canRenderSurveyAsync identify setPersonProperties group resetGroups setPersonPropertiesForFlags resetPersonPropertiesForFlags setGroupPropertiesForFlags resetGroupPropertiesForFlags reset get_distinct_id getGroups get_session_id get_session_replay_url alias set_config startSessionRecording stopSessionRecording sessionRecordingStarted captureException loadToolbar get_property getSessionProperty createPersonProfile opt_in_capturing opt_out_capturing has_opted_in_capturing has_opted_out_capturing clear_opt_in_out_capturing debug getPageViewId".split(" "),n=0;n<o.length;n++)g(u,o[n]);e._i.push([i,s,a])},e.__SV=1)}(document,window.posthog||[]);

  window.posthog.init('phc_vinarUZEJ5WnwLspys7fmFjmcP3YSdn89cMgz74rsNge', {
    api_host: 'https://us.i.posthog.com',
    defaults: '2026-05-30',              // PostHog's current defaults: page views on history changes, page leaves
    person_profiles: 'identified_only',  // nobody signs in here, so visitors stay anonymous
    autocapture: true,                   // clicks, form submits and rage clicks
    capture_dead_clicks: true,           // clicks that change nothing (a button that looks clickable but isn't)
    enable_heatmaps: true,               // where people click, move and scroll, for the heatmap toolbar
    capture_pageview: 'history_change',
    capture_pageleave: true,
    disable_session_recording: false,
    session_recording: {
      maskAllInputs: true,               // whatever is typed into a field is never recorded
    },
  });
})();
