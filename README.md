# Antigravity Local Installer

[![Windows installer CI](https://github.com/zxishui42/antigravity-local-installer/actions/workflows/windows-installer-ci.yml/badge.svg)](https://github.com/zxishui42/antigravity-local-installer/actions/workflows/windows-installer-ci.yml)

Windows installer source and regression tests for the paid Antigravity Local setup package.

Current validation target:

- Windows 10/11 x64
- Ollama
- Gemma 4 E2B

GitHub Actions is used to catch installer/runtime regressions before a real-PC acceptance test. Hosted CI does not replace the final AMD/NVIDIA GPU validation on physical hardware.


## Live test status

Open the **Actions** tab or click the badge above to see the current Windows test run, including each step and whether it is running, passed, or failed.
