# Meeting Coach · Ground-truth labels · 2026-07-14 leadership team

Purpose: backtest labels for the simulator (Phase 1 gate in the build plan). Run the app
against this transcript and compare fired nudges to the events below. Recall target: fire
on all SHOULD_FIRE events. Precision target: nothing fired during the NO_FIRE stretches
or on the HARD_NEGATIVE moments.

Transcript: `~/Dork Dropbox/noah kagan/AppSumo Transcripts/transcript-leadership-team-mtg.txt`
Participants: noah kagan (coached user), Anna Notario, Caitlin Yanke, Lyndsay, Matt Bean
Duration: 11:31:49 to 12:07:50 wall clock (36:01)

Harness notes:
- `simulator/backtest.py` consumes YAML notes with `signal_id` (rubric IDs from
  `rubrics/personal.yaml`, not S-codes), `t` as **elapsed mm:ss from meeting start
  (11:31:49)**, and `text`. Companion file: `leadership-2026-07-14-notes.yaml`.
- Match tolerance is ±90 s, so fire-time precision matters mostly for the lead-time metric.
- This transcript is in `HH:MM:SS --> HH:MM:SS` / `Speaker: text` (VTT-ish) format;
  `convert_zoom.py` only parses the Zoom Docs `**Speaker** · HH:MM:SS` format, so it
  needs a converter tweak before the simulator can ingest it.
- Signal-code mapping used below: S4 → `unaddressed_objection`, X1 → `stacked_asks`,
  X2 → `promise_vs_clock`, S7 → `hedge_not_pinned`, P# → `positive_reinforcement`.

## SHOULD_FIRE events

### Event 1
- signal_id: unaddressed_objection (S4)
- time: 11:34:05 (elapsed 02:16) · fire window 11:34:00–11:34:10
- trigger_text: noah 11:33:35 "How come you guys don't list it on AppSumo?" → Lyndsay
  11:33:39 "Because I don't think there's an overlap in the audience" → Lyndsay 11:33:45
  "Yeah, but like fiction writers" (second reason) → noah 11:33:49 "Is there, Caitlin,
  does it qualify for radar?" (repitch #2, rerouted to Caitlin) → noah 11:34:05 "I think
  it's just interesting to make something that potentially our customers want" (repitch #3)
- pattern: participant gives a reasoned no; user repitches the same idea without
  reflecting the reason. Third instance of the same intent lands at 11:34:05, 30 s after
  the first — that is the earliest fire consistent with the "third instance" rule.
  (Do not fire at 11:33:49: that is only the second instance.)
- nudge: "She said no with a reason. Say it back first."
- confidence_expected: high (explicit negation + repeated pitch intent). Caveat: the
  room's tone is playful (Lyndsay 11:34:29 "When y'all are desperate, you can pitch me"),
  so a tone-based suppressor must not eat this — the structural pattern still holds.
- Note: user self-corrects at 11:34:24 with the P4 handoff ("That would be Caitlin's
  call"), 19 s after fire. Good lead-time test: the nudge should beat the self-correction.

### Event 2
- signal_id: stacked_asks (X1)
- time: 12:06:56 (elapsed 35:07) · fire window 12:06:56–12:07:20
- trigger_text: noah issues in sequence, all to Lyndsay: come back with one-pager
  (12:06:25), define what you're optimizing for (12:06:34), think and come back
  (12:06:45), come back with options (12:06:56), state improvement baseline (12:07:02),
  double check with Caitlin (12:07:14). Six asks in 49 seconds.
- pattern: 4+ distinct asks to one person inside 90 seconds, none closed or confirmed
  before the next lands. The 4th ask arrives at 12:06:56 — that is the earliest legal
  fire; the previously listed window (12:06:25–12:06:49) contains only 3 asks.
  Note the recipient *does* acknowledge between asks (Lyndsay 12:06:27 "let me get you
  guys all of the information", 12:07:01 "Yeah, okay", 12:07:22 "I'll think about it"),
  so the detector must key on unclosed asks stacking, not on silence from the recipient.
- nudge: "Break down asks, one at a time."
- confidence_expected: high (this is the same pattern the app flagged at 90% in the June
  screenshot)
- Rubric gap: `stacked_asks` in personal.yaml reads "3+ asks bundled into ONE turn."
  These six asks span separate turns. Broaden the rubric description to "within a short
  window to one person" or this event can't fire.

### Event 3
- signal_id: unaddressed_objection (S4, answer-not-reflected variant)
- time: 12:07:01 (elapsed 35:12) · fire window 12:06:56–12:07:10
- trigger_text: noah 12:06:34 asks "what are you optimizing for?" → Lyndsay 12:06:40
  "What do you think we should optimize for? I guess I don't think we should optimize
  just for opens" → noah 12:06:45 deflects ("Yeah, think about that, and I would come
  back with it") → Lyndsay 12:06:47–50 answers anyway: "I think we should be optimizing
  for conversion rate" → Matt 12:06:52 "Net revenue" → noah 12:06:56 "Alright. Let's
  come back with a few of the options" — neither answer reflected.
- pattern: user asks a question, participant answers it, user's next utterance neither
  confirms nor references the answer. Can only be judged once the user's next utterance
  completes, so earliest fire is 12:06:56, not 12:06:47 as previously listed.
- nudge: "She just answered your question. Reflect it."
- confidence_expected: medium (overlapping speech, needs diarization)
- Collision: fires in the same breath as Event 2 (both ~12:06:56). The app needs a
  priority/dedup rule — see Tuning notes. For the backtest, either single nudge at this
  moment counts as a hit for its own event; firing both within 10 s counts as a nag.

### Event 4
- signal_id: promise_vs_clock (X2)
- time: 12:00:15 (elapsed 28:26) · fire condition: promise_time + 3× stated box
- trigger_text: noah 11:54:15 "Just real quick to. Let's try to box us another 2 min."
  Box expires 11:56:15; 3× elapsed at 12:00:15; meeting continues to 12:07:50.
- pattern: explicit time commitment detected, wall clock exceeds it by 3× with the user
  himself still opening new threads: 11:55:44 "Can we take a quick read of it?" (status
  read inside his own box), 11:56:04 conversion-tests question, 11:56:31 plus-features
  question, 11:59:02 event check. (The 12:01 August-priorities thread was opened by
  Anna, not the user — don't cite it as user evidence.)
- nudge: "You said 2 min, 6 min ago. Close or re-box."
- confidence_expected: high (deterministic timer trigger)
- Note: user partially self-acknowledges at 12:04:57 ("we're a little over time") —
  4:42 after fire. Another good lead-time measurement.

### Event 5
- signal_id: none yet — candidate v2 (private context surfaced live)
- time: 11:45:27 (elapsed 13:38)
- trigger_text: noah 11:45:27 "you kind of come into an NPS survey when we were chatting
  earlier, uh, your read on the team is that, like, people maybe aren't telling you the
  truth?" — attributing a private 1:1 read to Anna in front of the group
- pattern: user attributes an unverified private statement to a named participant in a
  group setting
- nudge: "That was a 1:1 read. Check before airing it."
- confidence_expected: low. Two-stage detection: the phrase "when we were chatting
  earlier" plus attributing a read to a named person is surface-detectable without any
  context object (cheap heuristic, low confidence). Confirming the source was private
  requires the pre-call context object ("Anna shared this 1:1 earlier today") — use this
  event to validate the context-loading upgrade from the June session, and to measure
  the confidence lift context provides over the surface heuristic.

### Event 6
- signal_id: hedge_not_pinned (S7)
- time: 12:02:10 (elapsed 30:21)
- trigger_text: Matt 12:01:55–12:02:10 "it'll not be, like, a 100% final proposal list
  by tomorrow… but yeah, that's on my radar to get things set there."
- pattern: deliverable softened from a date to "on my radar" with no new date stated;
  accepted without pinning
- nudge: "Radar isn't a date. Pin one."
- confidence_expected: medium, arguably low. Two wrinkles: (a) the exchange is
  Matt↔Anna — the coached user never spoke in this thread, so this tests whether the
  app should nudge the user about someone else's unpinned commitment; (b) Anna's
  12:02:08 "we can just talk tomorrow and work" is a concrete follow-up slot, which
  partially re-pins it. Treat a miss here as acceptable in v1.
- Rubric gap: `hedge_not_pinned` exists only in rubrics/default.yaml, not in
  personal.yaml — with the personal rubric this event can never match by signal_id.
  Add it (tier B) or map to `resolution_capture`.

## POSITIVE_REINFORCEMENT events (fire green, not corrective)

### P1
- signal_id: positive_reinforcement
- time: 11:32:11 (elapsed 00:22)
- trigger_text: noah "okay, I'm stopping, I gotta… I keep"
- pattern: self-interruption of a joke/tangent spiral. Reinforce.
- nudge: "Caught yourself. Nice."

### P2
- signal_id: positive_reinforcement
- time: 12:04:57 (elapsed 33:08)
- trigger_text: noah 12:04:55 "Can I just ask one question?" then "we're a little over
  time, but I… how… what would make it easy to make a decision?"
- pattern: decision-forcing question after extended ambiguity, plus spontaneous
  over-time acknowledgment. This is the archetype good move.
- nudge: "That question just saved 10 minutes."
- Note: user then reflects Lyndsay's answer at 12:05:23 ("Got it") — the healthy
  contrast to Event 3, 90 seconds before Event 3's miss.

### P3
- time: 11:45:09 (elapsed 13:20)
- trigger_text: noah "You guys wanna do this afterwards or?"
- pattern: parking a two-person troubleshooting thread (Anna's dashboard question) out
  of a group meeting
- nudge: none needed; log as a save (thread-parking)

### P4
- time: 11:34:24 (elapsed 02:35)
- trigger_text: noah "That would be Caitlin's call"
- pattern: explicit ownership handoff instead of deciding for the owner, 19 s after
  Event 1 — sequencing test: corrective at 02:16, green log at 02:35
- nudge: none needed; log as save

## NO_FIRE stretches (precision check: app should stay quiet)

- 11:35:25–11:38:05 (03:36–06:16) · appliance/robot-vacuum banter. Social warmup,
  intentional. A nag here is a false positive.
- 11:41:02–11:43:20 (09:13–11:31) · Anna's props round. Positive team maintenance, do
  not interrupt.
- 11:48:06–11:49:55 (16:17–18:06) · Matt's sentiment read. Long single-speaker stretch
  but substantive; talk-time monitor should not fire on a participant, only on the
  coached user.

## HARD_NEGATIVES (borderline moments that must NOT fire)

- 11:59:43 (27:54) · S4 near-miss. Lyndsay answers the site-setup question ("She sure
  is" / "It's entirely done by Claude at this point"); noah replies "Can we confirm
  that?" Looks like answer-not-reflected, but her answer was hedged ("I think", "I know
  she is…") — a verification request against a hedged answer is legitimate. Key
  discriminator for S4 precision.
- 11:55:22–11:55:34 (23:33–23:45) · X1 near-miss. Two rapid asks to Anna ("you feel
  good with this?" + "make the Summer Fridays decision"). Below the 4-ask threshold and
  the second is a clean delegation with an owner. Must stay quiet.
- 11:53:02–11:54:13 (21:13–22:24) · Matt pushes Anna on the NPS survey, Anna pushes
  back, Matt retreats ("Well, if you feel like that's set… that's fine"). Escalation
  shapes between two participants — the coach only fires on the coached user.

## Tuning notes

- S4 (`unaddressed_objection`) is the dominant miss category for this user (2 of the 6
  corrective events, and the P2→"Got it" contrast shows he can do it when present). If
  thresholds need loosening anywhere, loosen here first.
- X2 (`promise_vs_clock`) should be purely deterministic (regex on time-box phrases +
  wall clock). No LLM call needed; cheapest high-value trigger in the set.
- Collision policy: Events 2 and 3 fire within the same ~5 s. One nudge per 10 s max;
  when a structural signal (stacked_asks) and a conversational one
  (unaddressed_objection) collide, show the structural one — it's more actionable
  mid-meeting — and log the other.
- Rubric fixes needed before this backtest can pass: broaden `stacked_asks` beyond
  single-turn (Event 2), add `hedge_not_pinned` to personal.yaml (Event 6).
- Event 5 is the test case for the pre-call context object: the surface heuristic
  ("when we were chatting earlier" + attributed read) can propose it at low confidence,
  but only the context object ("Anna shared this 1:1 earlier today") can confirm.
  Measure the confidence delta.
- Converter: teach convert_zoom.py (or a sibling) the `HH:MM:SS --> HH:MM:SS` format
  before running this transcript through the simulator.
