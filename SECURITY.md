# Security policy

## Supported versions

The latest release gets security fixes. Please update before reporting something you found in an older one.

## Reporting a vulnerability

Please report security problems privately, not in a public issue.

1. Go to the repository's **Security** tab and choose **Report a vulnerability**.
2. If that option is not available, open an issue titled "Security contact request" with no details, and the maintainer will arrange a private channel.

Include what you found, the version, and steps to reproduce it. You will get an answer, and we will credit you in the fix if you want.

## What counts

AI Keeper deletes and moves files, and runs other programs, so the problems we most want to hear about are:

- removing or overwriting anything outside the folder a cleanup was meant to touch, including through symlinks or crafted names;
- running commands built from untrusted names, paths, branch names or skill contents;
- skipping the dry run, the confirmation or the recovery vault;
- leaking information off the Mac. The app makes no network requests of its own, so any network traffic from it is a bug.

Findings from the skills scanner are heuristics and not vulnerabilities in AI Keeper.
