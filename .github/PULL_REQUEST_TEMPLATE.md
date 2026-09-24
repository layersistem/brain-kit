## What changed

<!-- One topic. Name the hook or script and say what it does differently now. -->

## Why

<!-- The problem, with the measurement that showed it: the numbers and the method that produced them. -->

## How it was verified

- [ ] Shell scripts pass `bash -n` under bash 3.2, or use no feature newer than 3.2
- [ ] Python runs on the version under Requirements in README.md, standard library only
- [ ] Hooks stay silent on the happy path and exit 0 on failures they can survive
- [ ] Any text that reaches the model's context is bounded, and its source is stated below

## Context text

<!-- If this change adds text to the model's context: where does it come from and how is it bounded? Write "none" otherwise. -->

## CHANGELOG

- [ ] Entry added under "Unreleased" in CHANGELOG.md, written for the person upgrading

## Data

- [ ] No secrets, personal transcripts or vault content in the diff or in this description
