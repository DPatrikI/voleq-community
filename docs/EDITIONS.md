# VolEq and VolEq Pro

VolEq is designed as an open-core product with two separately distributed applications.

## VolEq

The public Community repository provides the complete open-source application
named **VolEq**, with:

- application or device-wide attachment;
- an application selector and refresh action;
- a start/stop leveling control;
- an on/off switch for speech-aware quiet-gain protection with automatic mild
  speech-noise suppression;
- safe recovery when the active system output route or Bluetooth profile changes;
- selectable native utility-window and menu-bar presentations;
- persistent local presentation preference and background operation after a
  control surface is dismissed;
- the maintained core algorithm and platform adapter;
- command-line build and test workflows.

VolEq must remain genuinely useful and reliable. It is not a crippled demo, a
trial, or an advertisement wrapper.

## VolEq Pro

The planned private repository may add separate proprietary files for:

- advanced leveling controls;
- automatic app selection, output-device preferences, and routing policies;
- profiles and per-app preferences;
- import/export, advanced exportable diagnostics, and guided recovery;
- Mac App Store distribution, if the audio topology can satisfy sandbox rules;
- commercial support and managed integrations.

VolEq Pro should consume tagged public packages rather than copying them.
Changes made to MPL-covered files remain governed by MPL-2.0. Separate Pro
files can use a proprietary license when they form a Larger Work in compliance
with MPL-2.0.

## Practical limitation of the boundary

Open-source users can modify VolEq and expose settings already present in the
DSP API. The business distinction therefore depends on official branding,
distribution, automation, polish, support, and maintained workflows—not on
hiding constants.
