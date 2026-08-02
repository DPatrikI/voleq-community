# Community and Premium editions

VolEq is designed as an open-core product with two separately distributed applications.

## VolEq Community

This public repository provides a useful, buildable application with:

- application or device-wide attachment;
- an application selector and refresh action;
- a start/stop leveling control;
- an on/off switch for speech-aware quiet-gain protection;
- a separate on/off switch for the automatic mild speech-noise-suppression
  preset;
- safe recovery when the active system output route or Bluetooth profile changes;
- the maintained core algorithm and platform adapter;
- command-line build and test workflows.

Community must remain genuinely useful and reliable. It is not a crippled demo, a trial, or an advertisement wrapper.

## VolEq Premium

The planned private repository may add separate proprietary files for:

- advanced leveling controls;
- automatic app selection, output-device preferences, and routing policies;
- profiles and per-app preferences;
- menu-bar and background workflows;
- import, export, diagnostics, and guided recovery;
- signed/notarized or App Store distribution;
- commercial support and managed integrations.

Premium should consume tagged public packages rather than copying them. Changes made to MPL-covered files remain governed by MPL-2.0. Separate Premium files can use a proprietary license when they form a Larger Work in compliance with MPL-2.0.

## Practical limitation of the boundary

Open-source users can modify Community and expose settings already present in the DSP API. The business distinction therefore depends on official branding, distribution, automation, polish, support, and maintained workflows—not on hiding constants.
