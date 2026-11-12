# Third-party material

AI Keeper itself is MIT licensed (see [LICENSE](LICENSE)). It includes or refers to the following.

## Fonts (SIL Open Font License 1.1)

These ship inside the app (`Contents/Resources/Fonts`) and are used on the website. Each licence text is next to the font in [`assets/fonts`](assets/fonts).

| Font | Copyright |
|---|---|
| Bricolage Grotesque | Copyright 2022 The Bricolage Grotesque Project Authors (https://github.com/ateliertriay/bricolage) |
| Jersey 15 | Copyright 2023 The Soft Type Project Authors (https://github.com/scfried/soft-type-jersey) |
| JetBrains Mono | Copyright 2020 The JetBrains Mono Project Authors (https://github.com/JetBrains/JetBrainsMono) |

## Logos

The logos of other tools (Claude, OpenAI, Gemini, Cursor, OpenCode, Pi, Git, Conductor, Superset, Goose, Aider and Z.ai) belong to their owners.
They are used only to identify the tools AI Keeper works with, and do not imply any endorsement.
The one-colour marks come from [Simple Icons](https://simpleicons.org) (CC0 1.0); the others are the tools' own app icons.
They are embedded from [`assets/tool-logos`](assets/tool-logos) by `scripts/gen-tool-logos.py`.

## Software it uses but does not include

- [NVIDIA SkillSpector](https://github.com/NVIDIA/SkillSpector) (Apache-2.0) scans skills. AI Keeper does not bundle it: it is installed on request with `uv`, and runs as a separate process.
- The GitHub CLI (`gh`), `git`, `docker` and `uv`, when you have them, are run as separate programs.
