# Decisions log

Why choices were made — append-only, newest last. One short entry per
decision: what was decided and the reason that would otherwise be lost.
Agents: append here when a non-obvious choice is made (or reversed);
never rewrite old entries — supersede them with a new one.

## 2026-07-20 — Zero-config pivot
Repositioned as a live Granola alternative: transcript + ambient stats
primary, default nudges cut ~20→5, config behind an Advanced disclosure.
Why: nudge volume read as nagging in real use; transcript value landed
immediately with zero setup.

## 2026-07-28 — Speaker names are never auto-applied
LLM name suggestions require a one-tap confirm. Why: a wrong name gets
saved with a voice profile and poisons every future session's enrollment.

## 2026-07-28 — Voice profiles stored at 16kHz
Audio is FIR-decimated 48k→16k at the capture boundary. Why: the LS-EEND
model runs at 16kHz natively, so higher rates only cost memory (3×) and
internal resampling — verified zero quality loss (voice band unity gain,
aliasing −52dB).

## 2026-07-29 — Referral codes are one shared code, counted locally
`coachfree` on AppSumo, 3 invites tracked on-device, never enforced.
Why: no backend exists (local-first constraint); scarcity drives sharing
but blocking generosity would be user-hostile. Unique per-user codes need
an API — revisit only if attribution becomes worth running a service.
