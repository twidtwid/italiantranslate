# Security

## Reporting a problem

Please report security problems privately, not in a public issue: on this repository's
**Security** tab, choose **Report a vulnerability**. Include what you found, how to reproduce it,
and what an attacker could do with it. This is a small project maintained in spare time; you'll
hear back as soon as possible, and fixes ship as a new TestFlight build.

## What's in scope

- **The app.** Traduci is built so that nothing leaves the iPhone: camera frames, recognised text
  and translations stay on the device, and the only network use is iOS downloading Apple's Italian
  language pack. Anything that sends data off the phone, or lets text on a menu or sign make the
  app do something it shouldn't, is a bug worth reporting.
- **The build pipeline.** The TestFlight workflow holds App Store Connect API credentials as
  repository secrets. Anything that could expose them (for example through a workflow that runs
  code from a pull request with those secrets available) is in scope.
- **TestFlight feedback.** The feedback workflow commits testers' comments and screenshots to this
  public repository encrypted to `scripts/feedback_public_key.pem`; only the matching private key,
  which is never committed, can read them. A way to read or tamper with them is in scope.

The latest build on the default branch is the one that's supported.
