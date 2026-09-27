-- Social interaction definitions (social module). Pure data: behaviour special to one
-- interaction lives in Sim/Conversation.lua (C.SPECIAL[id]). Every definition becomes an
-- executor interaction "soc_<id>" (targetActor = true) run by the conversation engine.
--
-- Fields
--   id, label, cat (menu group), kind: "neutral" | "friendly" | "fun" | "kind" | "hostile" | "romantic"
--   desc      tooltip text
--   who/whom  actor/target age: "any" (adult or child), "adult", "child"
--   need      declarative prerequisites (checked for menus and autonomy alike; see C.CHECKS):
--             met, unmet, minLife, theirLife, maxLife, closeOrFamily, family, household,
--             notHousehold, romance, crush, romanceBoth, partner, notPartner, notTaken, upset,
--             selfLow, conflict, owed, visitor, host, item, book, mess, loves, subject, session,
--             venue, guardianOf, energy
--   base      acceptance shift (chance = 50 + base + relationship + mood + personality + ...)
--   acc       target-side acceptance weights: rel, mood, nice, playful, outgoing, active, neat,
--             interest (topic interest), audience (per witness), charisma (speaker skill),
--             romance (target's romance toward the speaker), compat (personality match)
--   accA      speaker-side personality weights (e.g. nice people ask better questions)
--   rep       penalty per recent repeat of this interaction to the same person (6 h)
--   repFail   extra penalty per recent failure of it (repeated bad jokes get worse)
--   topic     nil | "speaker" | "speaker_love" | "listener" | "shared" | "safe"
--   dur/react minutes of the speaking phase and of the reaction phase
--   pose/listen  speaker/listener poses while speaking (pose vocabulary, ARCHITECTURE §8)
--   carry     prop the speaker holds while speaking (gift, flowers, book)
--   ok/no     outcome on acceptance / rejection:
--             mine/theirs = { d = daily, l = life, r = romance, v = rivalry } (speaker->target,
--             target->speaker), social/fun/comfort/energy = { speaker, target } need changes,
--             pose = { speaker, target } reaction poses, icon = { speaker, target } balloons,
--             line = situation, by = "a" | "b" (who says it), conflict, upset = minutes
--   open      situation for the speaker's opening caption
--   cooldown  minutes before this pair tries it again after a rejection
--   auto      autonomy weight (nil = player only); adv = autonomy advert { need = amount }
--   aff       extra personality affinity for autonomy (see SS.Personality.SocialAffinity)
--   group     may run inside a group conversation (other members react)
--   skill     { skill = points } practice for both participants (SS.Skills.Gain, guarded)
local _, SS = ...

local L = {}
local function def(t) L[#L + 1] = t end

---------------------------------------------------------------------------
-- Hello
def { id = "introduce", label = "Introduce Yourself", cat = "Hello", kind = "neutral", icon = "soc_hello",
    desc = "Say hello to someone new. First impressions depend on how alike you are.",
    need = { unmet = true }, base = 25, acc = { compat = 14, mood = 1 }, rep = 30, dur = 2, react = 1.5,
    pose = "greet", listen = "idle", open = "greet",
    ok = { mine = { d = 6, l = 2 }, theirs = { d = 6, l = 2 }, social = { 8, 8 }, pose = { "greet", "greet" },
           icon = { "react_hello", "react_hello" }, line = "greet", by = "b" },
    no = { mine = { d = -2 }, theirs = { d = -3, l = -1 }, social = { 2, 0 }, pose = { "idle", "idle" },
           icon = { "react_awkward", "react_shrug" } },
    cooldown = 120, auto = 1.3, adv = { social = 28 } }

def { id = "wave", label = "Wave Hello", cat = "Hello", kind = "neutral", icon = "soc_wave",
    desc = "A quick, friendly wave. Low risk, low reward; do it twice and it gets strange.",
    need = { met = true }, base = 30, rep = 22, dur = 1, react = 1, pose = "greet", listen = "idle",
    ok = { mine = { d = 2 }, theirs = { d = 3, l = 0.5 }, social = { 4, 4 }, pose = { "greet", "greet" },
           icon = { "react_hello", "react_hello" } },
    no = { theirs = { d = -1 }, social = { 1, 0 }, pose = { "idle", "idle" }, icon = { "react_awkward", "react_shrug" } },
    cooldown = 30, auto = 0.7, adv = { social = 10 }, group = true }

def { id = "handshake", label = "Shake Hands", cat = "Hello", kind = "neutral", icon = "soc_handshake",
    desc = "A proper grown-up greeting. Serious people appreciate it; playful people find it stiff.",
    who = "adult", whom = "adult", base = 20, acc = { playful = -3, outgoing = 1 }, rep = 25, dur = 1.5, react = 1,
    pose = "greet", listen = "greet",
    ok = { mine = { d = 3, l = 1 }, theirs = { d = 5, l = 1.5 }, social = { 6, 6 }, pose = { "greet", "greet" },
           icon = { "react_handshake", "react_handshake" } },
    no = { theirs = { d = -2 }, social = { 1, 0 }, pose = { "greet", "idle" }, icon = { "react_handshake", "react_awkward" } },
    cooldown = 60, auto = 0.5, adv = { social = 15 } }

def { id = "greet_hug", label = "Hello Hug", cat = "Hello", kind = "friendly", icon = "soc_hug",
    desc = "Greet a friend or relative with a hug. Too familiar for acquaintances.",
    need = { closeOrFamily = 25 }, base = 10, acc = { rel = 1.2, outgoing = 2, nice = 1 }, rep = 20, dur = 1.5, react = 1.5,
    pose = "hug", listen = "hug",
    ok = { mine = { d = 5, l = 1.5 }, theirs = { d = 7, l = 2 }, social = { 10, 10 }, comfort = { 3, 3 },
           pose = { "hug", "hug" }, icon = { "react_heart", "react_heart" } },
    no = { mine = { d = -3 }, theirs = { d = -6, l = -1 }, social = { -2, 0 }, pose = { "idle", "idle" },
           icon = { "react_awkward", "react_no" } },
    cooldown = 120, auto = 0.7, adv = { social = 25 } }

def { id = "farewell", label = "Say Goodbye", cat = "Hello", kind = "neutral", icon = "soc_bye",
    desc = "Wish someone well. A visitor who is said goodbye to heads home happily.",
    need = { met = true }, base = 40, rep = 30, dur = 1.5, react = 1, pose = "greet", listen = "greet", open = "farewell",
    ok = { mine = { d = 2 }, theirs = { d = 3, l = 1 }, social = { 3, 3 }, pose = { "greet", "greet" },
           icon = { "react_bye", "react_bye" }, line = "farewell", by = "b" },
    no = { theirs = { d = -1 }, social = { 1, 0 }, pose = { "greet", "idle" }, icon = { "react_bye", "react_shrug" } },
    cooldown = 30 }

---------------------------------------------------------------------------
-- Talk
def { id = "small_talk", label = "Small Talk", cat = "Talk", kind = "neutral", icon = "soc_talk",
    desc = "The weather, the bus shelter, the price of cheese. Safe with anyone, dull when repeated.",
    base = 22, acc = { outgoing = 1 }, rep = 10, topic = "safe", dur = 2.5, react = 1.5, pose = "talk", listen = "idle",
    open = "smalltalk",
    ok = { mine = { d = 3, l = 0.8 }, theirs = { d = 4, l = 1 }, social = { 9, 9 }, pose = { "talk", "laugh" },
           icon = { "topic", "react_yes" } },
    no = { mine = { d = -1 }, theirs = { d = -2 }, social = { 3, 1 }, pose = { "idle", "idle" },
           icon = { "topic", "react_awkward" } },
    cooldown = 20, auto = 1.5, adv = { social = 30 }, group = true }

def { id = "ask_day", label = "Ask About Their Day", cat = "Talk", kind = "friendly", icon = "soc_question",
    desc = "Ask how things are going. Someone having a rotten day will tell you all about it.",
    need = { met = true }, base = 25, acc = { mood = 1.5 }, accA = { nice = 2 }, rep = 18, dur = 2, react = 2,
    pose = "talk", listen = "idle", open = "ask_day",
    ok = { mine = { d = 3, l = 0.5 }, theirs = { d = 5, l = 1.5 }, social = { 8, 10 }, pose = { "talk", "talk" },
           icon = { "react_question", "react_yes" }, line = "smalltalk", by = "b" },
    no = { theirs = { d = -2 }, social = { 2, 0 }, pose = { "idle", "idle" }, icon = { "react_question", "react_shrug" } },
    cooldown = 60, auto = 1.0, adv = { social = 25 } }

def { id = "chat_hobby", label = "Chat About Hobbies", cat = "Talk", kind = "friendly", icon = "soc_talk",
    desc = "Talk about your favourite subject. Goes well if they share the interest, badly if they hate it.",
    base = 10, acc = { interest = 1, compat = 4 }, rep = 12, topic = "speaker", dur = 3, react = 1.5,
    pose = "talk", listen = "idle", open = "topic_love",
    ok = { mine = { d = 5, l = 1.5 }, theirs = { d = 6, l = 2 }, social = { 11, 9 }, fun = { 4, 4 },
           pose = { "talk", "laugh" }, icon = { "topic", "react_yes" }, line = "topic_love", by = "b" },
    no = { mine = { d = -1 }, theirs = { d = -4, l = -1 }, social = { 3, -2 }, fun = { 0, -4 },
           pose = { "talk", "idle" }, icon = { "topic", "react_bored" }, line = "topic_hate", by = "b" },
    cooldown = 45, auto = 1.2, adv = { social = 30, fun = 8 }, group = true }

def { id = "ask_hobbies", label = "Ask About Their Hobbies", cat = "Talk", kind = "friendly", icon = "soc_question",
    desc = "Get them talking about what they love. They enjoy it more than you do, unless you share it.",
    base = 25, acc = { interest = 0.5, outgoing = 1 }, accA = { nice = 2 }, rep = 12, topic = "listener", dur = 2.5, react = 2,
    pose = "talk", listen = "idle",
    ok = { mine = { d = 3, l = 1 }, theirs = { d = 8, l = 2.5 }, social = { 7, 12 }, fun = { 1, 5 },
           pose = { "talk", "talk" }, icon = { "react_question", "topic" }, line = "topic_love", by = "b" },
    no = { theirs = { d = -2 }, social = { 2, 1 }, pose = { "idle", "idle" }, icon = { "react_question", "react_shrug" } },
    cooldown = 45, auto = 1.0, adv = { social = 28 }, group = true }

def { id = "share_enthusiasm", label = "Gush About a Passion", cat = "Talk", kind = "fun", icon = "soc_talk",
    desc = "Talk at length about the thing you love most. Wonderful for a fellow fan; torture for someone who hates it.",
    need = { loves = true }, base = 0, acc = { interest = 1.6, outgoing = 1 }, rep = 15, topic = "speaker_love",
    dur = 3.5, react = 2, pose = "talk", listen = "idle", open = "topic_love",
    ok = { mine = { d = 8, l = 2.5 }, theirs = { d = 9, l = 3 }, social = { 14, 12 }, fun = { 8, 8 },
           pose = { "talk", "laugh" }, icon = { "topic", "react_heart" }, line = "topic_love", by = "b" },
    no = { mine = { d = -2 }, theirs = { d = -7, l = -2 }, social = { 4, -4 }, fun = { 3, -8 },
           pose = { "talk", "idle" }, icon = { "topic", "react_bored" }, line = "topic_hate", by = "b" },
    cooldown = 90, auto = 1.0, adv = { social = 32, fun = 10 }, aff = { outgoing = 0.5 }, group = true }

def { id = "debate", label = "Friendly Debate", cat = "Talk", kind = "friendly", icon = "soc_debate",
    desc = "Argue a topic you both know, for sport. Serious people love it. Grouchy people take it personally.",
    need = { met = true }, base = 5, acc = { playful = -2, nice = 2.5 }, rep = 12, topic = "shared", dur = 4, react = 2,
    pose = "talk", listen = "talk", skill = { logic = 0.05 },
    ok = { mine = { d = 5, l = 2 }, theirs = { d = 5, l = 2 }, social = { 10, 10 }, fun = { 5, 5 },
           pose = { "laugh", "laugh" }, icon = { "topic", "react_idea" } },
    no = { mine = { d = -5, l = -1, v = 8 }, theirs = { d = -6, l = -2, v = 8 }, social = { 2, 2 },
           pose = { "argue", "argue" }, icon = { "react_angry", "react_angry" }, line = "argue", by = "b", conflict = true },
    cooldown = 90, auto = 0.8, adv = { social = 25, fun = 6 }, aff = { playful = -0.8 }, group = true }

def { id = "gossip", label = "Gossip", cat = "Talk", kind = "fun", icon = "soc_gossip",
    desc = "Share news about someone you both know. Bonding for gossips, off-putting for nice people, and a "
        .. "disaster if the subject overhears.",
    need = { met = true, subject = true }, base = 10, acc = { nice = -3, outgoing = 1.5 }, rep = 10, dur = 3, react = 1.5,
    pose = "talk", listen = "talk", open = "gossip",
    ok = { mine = { d = 4, l = 1 }, theirs = { d = 6, l = 1.5 }, social = { 10, 9 }, fun = { 6, 6 },
           pose = { "laugh", "laugh" }, icon = { "soc_gossip", "react_whisper" } },
    no = { theirs = { d = -5, l = -1 }, social = { 2, 0 }, pose = { "talk", "idle" }, icon = { "soc_gossip", "react_no" } },
    cooldown = 60, auto = 0.9, adv = { social = 28, fun = 6 }, aff = { nice = -0.6, outgoing = 0.5 }, group = true }

def { id = "complain", label = "Complain About Life", cat = "Talk", kind = "neutral", icon = "soc_complain",
    desc = "Get it off your chest. Only when you're in a mood. Nice listeners sympathise; grouchy ones sigh.",
    need = { selfLow = true }, base = 10, acc = { nice = 3 }, rep = 15, dur = 3, react = 1.5, pose = "talk", listen = "idle",
    open = "complain",
    ok = { mine = { d = 6, l = 2 }, theirs = { d = 2, l = 1 }, social = { 10, 4 }, comfort = { 4, 0 },
           pose = { "talk", "talk" }, icon = { "react_sad", "react_yes" }, line = "comfort", by = "b" },
    no = { mine = { d = -3 }, theirs = { d = -5, l = -1 }, social = { 3, -2 }, pose = { "talk", "idle" },
           icon = { "react_sad", "react_bored" } },
    cooldown = 90, auto = 0.8, adv = { social = 25 }, aff = { nice = -0.3 } }

def { id = "ask_advice", label = "Ask for Advice", cat = "Family", kind = "friendly", icon = "soc_question",
    desc = "Ask someone wiser (or at least more skilled) what they'd do. They like being asked; you might learn something.",
    need = { met = true }, base = 20, acc = { nice = 2 }, rep = 20, dur = 3, react = 1.5, pose = "talk", listen = "talk", open = "advice",
    ok = { mine = { d = 5, l = 2 }, theirs = { d = 6, l = 2.5 }, social = { 8, 8 }, pose = { "talk", "talk" },
           icon = { "react_question", "react_idea" } },
    no = { mine = { d = -2 }, theirs = { d = -2 }, social = { 2, 0 }, pose = { "idle", "idle" },
           icon = { "react_question", "react_shrug" } },
    cooldown = 120, auto = 0.5, adv = { social = 22 } }

def { id = "reminisce", label = "Reminisce", cat = "Family", kind = "friendly", icon = "soc_story",
    desc = "Relive old times with family or an old friend. Long, warm and good for the relationship.",
    need = { met = true, closeOrFamily = 40 }, base = 25, rep = 20, dur = 5, react = 2, pose = "talk", listen = "laugh",
    open = "story",
    ok = { mine = { d = 8, l = 4 }, theirs = { d = 8, l = 4 }, social = { 14, 14 }, fun = { 6, 6 },
           pose = { "laugh", "laugh" }, icon = { "react_heart", "react_heart" } },
    no = { mine = { d = -2 }, theirs = { d = -3, l = -1 }, social = { 4, 2 }, pose = { "talk", "idle" },
           icon = { "react_sad", "react_bored" } },
    cooldown = 180, auto = 0.6, adv = { social = 35 } }

def { id = "boast", label = "Boast", cat = "Talk", kind = "neutral", icon = "soc_boast",
    desc = "Mention your best skill, your job or your savings. Works on the easily impressed. A mess nearby undercuts it.",
    base = 5, acc = { nice = 1 }, rep = 15, dur = 2, react = 2, pose = "talk", listen = "idle", open = "boast",
    ok = { mine = { d = 4, l = 0.5 }, theirs = { d = 3, l = 1 }, social = { 8, 3 }, pose = { "celebrate", "talk" },
           icon = { "soc_boast", "react_yes" } },
    no = { mine = { d = -1 }, theirs = { d = -6, l = -1.5 }, social = { 2, -2 }, pose = { "talk", "idle" },
           icon = { "soc_boast", "react_bored" } },
    cooldown = 120, auto = 0.6, adv = { social = 22 }, aff = { outgoing = 0.8, nice = -0.4 } }

---------------------------------------------------------------------------
-- Fun
def { id = "joke", label = "Tell a Joke", cat = "Fun", kind = "fun", icon = "soc_joke",
    desc = "Playful people laugh; serious people don't. Each flop makes the next joke to them worse.",
    base = 8, acc = { playful = 3.5, audience = 1 }, rep = 8, repFail = 14, dur = 2, react = 2, pose = "talk", listen = "idle",
    ok = { mine = { d = 4, l = 1 }, theirs = { d = 6, l = 1.5 }, social = { 9, 8 }, fun = { 8, 12 },
           pose = { "laugh", "laugh" }, icon = { "soc_joke", "react_laugh" }, line = "joke_good", by = "b" },
    no = { mine = { d = -2 }, theirs = { d = -5, l = -1 }, social = { -1, -2 }, fun = { -2, -4 },
           pose = { "idle", "idle" }, icon = { "soc_joke", "react_awkward" }, line = "joke_bad", by = "a" },
    cooldown = 60, auto = 1.2, adv = { social = 25, fun = 20 }, aff = { playful = 1 }, group = true }

def { id = "pun", label = "Try a Pun", cat = "Fun", kind = "fun", icon = "soc_pun",
    desc = "Only the truly playful enjoy a pun. Everyone else groans, which is at least a reaction.",
    base = -15, acc = { playful = 6 }, rep = 10, repFail = 10, dur = 1.5, react = 1.5, pose = "talk", listen = "idle",
    ok = { mine = { d = 3 }, theirs = { d = 4, l = 1 }, social = { 6, 6 }, fun = { 6, 9 },
           pose = { "laugh", "laugh" }, icon = { "soc_pun", "react_laugh" }, line = "joke_good", by = "b" },
    no = { mine = { d = -1 }, theirs = { d = -2 }, social = { 1, 0 }, fun = { 2, -2 },
           pose = { "celebrate", "idle" }, icon = { "soc_pun", "react_groan" }, line = "joke_bad", by = "b" },
    cooldown = 45, auto = 0.7, adv = { social = 18, fun = 15 }, aff = { playful = 1.2 }, group = true }

def { id = "story", label = "Tell a Funny Story", cat = "Fun", kind = "fun", icon = "soc_story",
    desc = "A long anecdote about your favourite subject. Better with an audience, if it lands.",
    base = 12, acc = { playful = 2, interest = 0.6, audience = 3 }, rep = 12, topic = "speaker", dur = 4, react = 2,
    pose = "talk", listen = "idle", open = "story",
    ok = { mine = { d = 5, l = 1.5 }, theirs = { d = 7, l = 2 }, social = { 12, 10 }, fun = { 10, 12 },
           pose = { "laugh", "laugh" }, icon = { "topic", "react_laugh" }, line = "joke_good", by = "b" },
    no = { theirs = { d = -4, l = -1 }, social = { 2, -1 }, fun = { 0, -4 }, pose = { "talk", "idle" },
           icon = { "topic", "react_bored" }, line = "joke_bad", by = "a" },
    cooldown = 90, auto = 0.9, adv = { social = 30, fun = 18 }, aff = { playful = 0.8, outgoing = 0.5 }, group = true }

def { id = "tease", label = "Tease", cat = "Fun", kind = "fun", icon = "soc_tease",
    desc = "Gentle mockery. Friends laugh; everyone else takes offence.",
    need = { met = true }, base = 0, acc = { playful = 3, nice = 1, rel = 1.4 }, rep = 10, repFail = 10, dur = 1.5, react = 1.5,
    pose = "laugh", listen = "idle", open = "tease",
    ok = { mine = { d = 4, l = 1 }, theirs = { d = 4, l = 1 }, social = { 7, 6 }, fun = { 10, 8 },
           pose = { "laugh", "laugh" }, icon = { "soc_tease", "react_laugh" } },
    no = { mine = { d = -2 }, theirs = { d = -9, l = -2.5, v = 6 }, social = { 2, -4 }, fun = { 3, -4 },
           pose = { "laugh", "argue" }, icon = { "soc_tease", "react_angry" }, line = "argue", by = "b", conflict = true },
    cooldown = 90, auto = 0.7, adv = { social = 20, fun = 22 }, aff = { playful = 1, nice = -0.4 }, group = true }

def { id = "impression", label = "Do an Impression", cat = "Fun", kind = "fun", icon = "soc_impression",
    desc = "Imitate someone you both know. Hilarious, unless they are standing right there.",
    need = { met = true, subject = true }, base = 5, acc = { playful = 3, audience = 2 }, rep = 15, dur = 3, react = 2,
    pose = "talk", listen = "idle", open = "tease",
    ok = { mine = { d = 4 }, theirs = { d = 6, l = 1 }, social = { 9, 8 }, fun = { 12, 12 },
           pose = { "laugh", "laugh" }, icon = { "soc_impression", "react_laugh" }, line = "joke_good", by = "b" },
    no = { theirs = { d = -5, l = -1 }, social = { 0, -2 }, fun = { -2, -4 }, pose = { "idle", "idle" },
           icon = { "soc_impression", "react_awkward" }, line = "joke_bad", by = "a" },
    cooldown = 120, auto = 0.5, adv = { fun = 22, social = 18 }, aff = { playful = 1, outgoing = 0.8 }, group = true }

---------------------------------------------------------------------------
-- Games (no board needed)
def { id = "thumb_war", label = "Thumb Wrestle", cat = "Games", kind = "fun", icon = "soc_game",
    desc = "A quick contest. The winner is chuffed; a grouchy loser holds a grudge.",
    need = { met = true }, base = 25, acc = { playful = 3, active = 1 }, rep = 15, dur = 3, react = 1.5,
    pose = "play", listen = "play", open = "game_thumb",
    ok = { mine = { d = 4, l = 1 }, theirs = { d = 4, l = 1 }, social = { 6, 6 }, fun = { 12, 12 },
           pose = { "celebrate", "laugh" }, icon = { "react_trophy", "react_laugh" } },
    no = { theirs = { d = -2 }, social = { 1, 0 }, pose = { "idle", "idle" }, icon = { "soc_game", "react_no" } },
    cooldown = 60, auto = 0.6, adv = { fun = 25, social = 12 }, aff = { playful = 1 } }

def { id = "play_tag", label = "Play Tag", cat = "Games", kind = "fun", icon = "soc_tag",
    desc = "Run about. Children adore it; lazy adults would rather not. Tiring.",
    need = { energy = -30 }, base = 10, acc = { playful = 2, active = 3 }, rep = 12, dur = 5, react = 1.5,
    pose = "run", listen = "run", open = "game_tag",
    ok = { mine = { d = 6, l = 2 }, theirs = { d = 6, l = 2 }, social = { 8, 8 }, fun = { 18, 18 }, energy = { -6, -6 },
           pose = { "laugh", "laugh" }, icon = { "soc_tag", "react_laugh" } },
    no = { theirs = { d = -1 }, social = { 1, 0 }, pose = { "idle", "idle" }, icon = { "soc_tag", "react_no" } },
    cooldown = 60, auto = 0.7, adv = { fun = 30, social = 10 }, aff = { active = 1, playful = 0.8 } }

def { id = "guessing_game", label = "Play a Guessing Game", cat = "Games", kind = "fun", icon = "soc_guess",
    desc = "Guess what they're thinking of in twenty questions or fewer. Quietly clever fun.",
    base = 18, acc = { playful = -1, outgoing = 1 }, rep = 12, dur = 4, react = 1.5, pose = "talk", listen = "talk", open = "game_guess",
    skill = { logic = 0.03 },
    ok = { mine = { d = 4, l = 1.5 }, theirs = { d = 4, l = 1.5 }, social = { 8, 8 }, fun = { 10, 10 },
           pose = { "laugh", "celebrate" }, icon = { "soc_guess", "react_idea" } },
    no = { theirs = { d = -2 }, social = { 2, 0 }, fun = { 0, -2 }, pose = { "idle", "idle" }, icon = { "soc_guess", "react_bored" } },
    cooldown = 60, auto = 0.6, adv = { fun = 20, social = 15 }, aff = { playful = -0.3 }, group = true }

---------------------------------------------------------------------------
-- Kind
def { id = "compliment", label = "Compliment", cat = "Kind", kind = "kind", icon = "soc_compliment",
    desc = "Say something nice. It means most to someone who's feeling low.",
    base = 22, acc = { nice = 1.5 }, rep = 12, dur = 1.5, react = 1.5, pose = "talk", listen = "idle", open = "compliment",
    ok = { mine = { d = 2 }, theirs = { d = 7, l = 2 }, social = { 6, 9 }, pose = { "talk", "laugh" },
           icon = { "soc_compliment", "react_heart" } },
    no = { theirs = { d = -3 }, social = { 1, 0 }, pose = { "talk", "idle" }, icon = { "soc_compliment", "react_shrug" } },
    cooldown = 60, auto = 1.0, adv = { social = 25 }, aff = { nice = 1 }, group = true }

def { id = "flatter", label = "Lay It On Thick", cat = "Kind", kind = "kind", icon = "soc_flatter",
    desc = "Extravagant praise. Big reward if they believe it; serious and grouchy people see straight through it.",
    base = -5, acc = { nice = 1, playful = 1, charisma = 2 }, rep = 20, dur = 2, react = 1.5, pose = "talk", listen = "idle",
    open = "compliment",
    ok = { mine = { d = 2 }, theirs = { d = 11, l = 3 }, social = { 6, 11 }, pose = { "talk", "laugh" },
           icon = { "soc_flatter", "react_heart" } },
    no = { mine = { d = -1 }, theirs = { d = -7, l = -2 }, social = { 0, -2 }, pose = { "talk", "argue" },
           icon = { "soc_flatter", "react_suspicious" } },
    cooldown = 120, auto = 0.4, adv = { social = 22 }, aff = { outgoing = 1, nice = -0.3 } }

def { id = "comfort", label = "Comfort", cat = "Kind", kind = "kind", icon = "soc_comfort",
    desc = "Console someone who is upset or grieving. Harder if you caused it.",
    need = { upset = true }, base = 25, acc = { rel = 1.2 }, rep = 10, dur = 2.5, react = 2, pose = "hug", listen = "cry",
    open = "comfort",
    ok = { mine = { d = 4, l = 1.5 }, theirs = { d = 9, l = 3 }, social = { 6, 12 }, comfort = { 0, 10 },
           pose = { "hug", "hug" }, icon = { "soc_comfort", "react_heart" } },
    no = { mine = { d = -2 }, theirs = { d = -4 }, social = { 1, -1 }, pose = { "idle", "cry" },
           icon = { "soc_comfort", "react_no" }, line = "argue", by = "b" },
    cooldown = 60, auto = 1.3, adv = { social = 25 }, aff = { nice = 1 } }

def { id = "apologize", label = "Apologise", cat = "Kind", kind = "kind", icon = "soc_sorry",
    desc = "Make up after an argument, an insult or a sore joke. Too soon and they're still cross.",
    need = { conflict = true }, base = 15, acc = { nice = 3, rel = 0.8 }, rep = 20, dur = 2, react = 2,
    pose = "talk", listen = "idle", open = "apologize",
    ok = { mine = { d = 8, l = 2 }, theirs = { d = 15, l = 3 }, social = { 8, 8 }, pose = { "talk", "hug" },
           icon = { "soc_sorry", "react_heart" } },
    no = { mine = { d = -2 }, theirs = { d = -3 }, social = { 2, 0 }, pose = { "talk", "argue" },
           icon = { "soc_sorry", "react_angry" }, line = "argue", by = "b" },
    cooldown = 120, auto = 1.0, adv = { social = 25 }, aff = { nice = 1 } }

def { id = "thank", label = "Say Thanks", cat = "Kind", kind = "kind", icon = "soc_thanks",
    desc = "Thank someone for a kindness they did you recently.",
    need = { owed = true }, base = 35, rep = 30, dur = 1.5, react = 1.5, pose = "talk", listen = "idle", open = "thanks",
    ok = { mine = { d = 3, l = 1 }, theirs = { d = 6, l = 2 }, social = { 6, 6 }, pose = { "talk", "laugh" },
           icon = { "soc_thanks", "react_heart" } },
    no = { theirs = { d = -1 }, social = { 2, 0 }, pose = { "talk", "idle" }, icon = { "soc_thanks", "react_shrug" } },
    cooldown = 120, auto = 0.8, adv = { social = 18 }, aff = { nice = 0.8 } }

---------------------------------------------------------------------------
-- Affection (friendly)
def { id = "high_five", label = "High Five", cat = "Affection", kind = "friendly", icon = "soc_highfive",
    desc = "Celebrate together. Leaving someone hanging is its own kind of comedy.",
    need = { met = true }, base = 20, acc = { playful = 2, rel = 1 }, rep = 15, dur = 1, react = 1,
    pose = "celebrate", listen = "idle",
    ok = { mine = { d = 4, l = 1 }, theirs = { d = 4, l = 1 }, social = { 5, 5 }, fun = { 5, 5 },
           pose = { "celebrate", "celebrate" }, icon = { "soc_highfive", "react_laugh" } },
    no = { mine = { d = -2 }, theirs = { d = -2 }, social = { -1, 0 }, pose = { "celebrate", "idle" },
           icon = { "soc_highfive", "react_awkward" } },
    cooldown = 30, auto = 0.7, adv = { social = 12, fun = 8 }, aff = { playful = 0.8 }, group = true }

def { id = "hug", label = "Friendly Hug", cat = "Affection", kind = "friendly", icon = "soc_hug",
    desc = "A warm hug for a friend or relative. Too much for anyone else.",
    need = { closeOrFamily = 30 }, base = 15, acc = { rel = 1.2, outgoing = 1 }, rep = 15, dur = 1.5, react = 1.5,
    pose = "hug", listen = "hug",
    ok = { mine = { d = 7, l = 2 }, theirs = { d = 8, l = 2.5 }, social = { 12, 12 }, comfort = { 4, 4 },
           pose = { "hug", "hug" }, icon = { "soc_hug", "react_heart" } },
    no = { mine = { d = -4 }, theirs = { d = -7, l = -2 }, social = { -2, 0 }, pose = { "idle", "idle" },
           icon = { "soc_hug", "react_no" } },
    cooldown = 120, auto = 0.8, adv = { social = 28 }, aff = { nice = 0.5, outgoing = 0.5 } }

def { id = "back_rub", label = "Back Rub", cat = "Affection", kind = "friendly", icon = "soc_backrub",
    desc = "Ease their aches. Only for people who are already close.",
    who = "adult", whom = "adult", need = { closeOrFamily = 45 }, base = 5, acc = { rel = 1.2 }, rep = 20, dur = 3, react = 1.5,
    pose = "use", listen = "idle",
    ok = { mine = { d = 4, l = 1 }, theirs = { d = 8, l = 2.5 }, social = { 6, 8 }, comfort = { 0, 15 },
           pose = { "use", "laugh" }, icon = { "soc_backrub", "react_heart" } },
    no = { mine = { d = -3 }, theirs = { d = -8, l = -2 }, social = { -2, 0 }, pose = { "idle", "argue" },
           icon = { "soc_backrub", "react_no" } },
    cooldown = 180, auto = 0.4, adv = { social = 18, comfort = 10 }, aff = { nice = 0.6 } }

def { id = "pat_back", label = "Pat on the Back", cat = "Affection", kind = "friendly", icon = "soc_pat",
    desc = "A brief, encouraging pat. Fine for acquaintances.",
    need = { met = true }, base = 30, rep = 15, dur = 1, react = 1, pose = "use", listen = "idle",
    ok = { mine = { d = 2 }, theirs = { d = 4, l = 1 }, social = { 4, 5 }, pose = { "use", "laugh" },
           icon = { "soc_pat", "react_yes" } },
    no = { theirs = { d = -2 }, social = { 1, 0 }, pose = { "use", "idle" }, icon = { "soc_pat", "react_shrug" } },
    cooldown = 30, auto = 0.6, adv = { social = 12 }, aff = { nice = 0.4 }, group = true }

---------------------------------------------------------------------------
-- Mean
def { id = "argue", label = "Argue", cat = "Mean", kind = "hostile", icon = "soc_argue",
    desc = "Pick a fight. Nice people back down; grouchy people give as good as they get. Either way it hurts.",
    need = { met = true }, base = 0, acc = { nice = 2, mood = 0.5 }, rep = 10, dur = 2.5, react = 2,
    pose = "argue", listen = "argue", open = "argue",
    ok = { mine = { d = -4, l = -1, v = 5 }, theirs = { d = -10, l = -3, v = 10 }, social = { 4, -4 },
           pose = { "argue", "idle" }, icon = { "soc_argue", "react_sad" }, conflict = true, upset = 90 },
    no = { mine = { d = -10, l = -3, v = 12 }, theirs = { d = -14, l = -4, v = 12 }, social = { 2, -2 },
           pose = { "argue", "argue" }, icon = { "soc_argue", "react_angry" }, line = "argue", by = "b", conflict = true },
    cooldown = 120, auto = 0.5, adv = { social = 12, fun = 6 }, aff = { nice = -1.2 }, group = true }

def { id = "insult", label = "Insult", cat = "Mean", kind = "hostile", icon = "soc_insult",
    desc = "Say something cruel. The target is hurt or fires back, and anyone watching thinks less of you.",
    need = { met = true }, base = 0, acc = { nice = 2, mood = 0.5 }, rep = 10, dur = 1.5, react = 2,
    pose = "argue", listen = "idle", open = "insult",
    ok = { mine = { d = -3, l = -1 }, theirs = { d = -16, l = -5, v = 10 }, social = { 4, -8 },
           pose = { "argue", "cry" }, icon = { "soc_insult", "react_sad" }, conflict = true, upset = 180 },
    no = { mine = { d = -8, l = -2, v = 10 }, theirs = { d = -18, l = -6, v = 14 }, social = { 2, -4 },
           pose = { "argue", "argue" }, icon = { "soc_insult", "react_angry" }, line = "argue", by = "b", conflict = true },
    cooldown = 180, auto = 0.35, adv = { social = 8, fun = 8 }, aff = { nice = -1.5 }, group = true }

def { id = "bicker_chores", label = "Bicker About Chores", cat = "Mean", kind = "hostile", icon = "soc_chores",
    desc = "Point out whose turn it is. A neat housemate may give in and clean; otherwise it's a row.",
    need = { household = true, mess = true }, base = 5, acc = { nice = 2, neat = 3 }, rep = 15, dur = 2.5, react = 2,
    pose = "argue", listen = "idle", open = "chores_argument",
    ok = { mine = { d = 2 }, theirs = { d = -3 }, social = { 4, 2 }, pose = { "argue", "idle" },
           icon = { "soc_chores", "react_yes" }, line = "chores_argument", by = "b" },
    no = { mine = { d = -6, l = -2, v = 6 }, theirs = { d = -8, l = -2, v = 8 }, social = { 3, -2 },
           pose = { "argue", "argue" }, icon = { "soc_chores", "react_angry" }, line = "chores_argument", by = "b",
           conflict = true },
    cooldown = 240, auto = 0.7, adv = { social = 10, room = 20 }, aff = { neat = 1.2, nice = -0.3 } }

def { id = "mock_hobby", label = "Mock Their Hobby", cat = "Mean", kind = "hostile", icon = "soc_tease",
    desc = "Make fun of the thing they love most. They'll either laugh it off or never forget it.",
    need = { met = true }, base = 0, acc = { nice = 2 }, rep = 15, topic = "listener", dur = 2, react = 2,
    pose = "laugh", listen = "idle", open = "insult",
    ok = { mine = { d = -1 }, theirs = { d = -6, l = -2 }, social = { 4, -2 }, fun = { 6, -3 },
           pose = { "laugh", "idle" }, icon = { "topic", "react_shrug" } },
    no = { mine = { d = -3 }, theirs = { d = -14, l = -4, v = 8 }, social = { 2, -6 }, pose = { "laugh", "argue" },
           icon = { "topic", "react_angry" }, line = "argue", by = "b", conflict = true },
    cooldown = 240, auto = 0.3, adv = { fun = 12, social = 6 }, aff = { nice = -1.3, playful = 0.4 }, group = true }

---------------------------------------------------------------------------
-- Romance (adults only, never close family; any pairing)
def { id = "flirt", label = "Flirt", cat = "Romance", kind = "romantic", icon = "soc_flirt",
    desc = "Test the waters. Works better in private, and on someone who already likes you.",
    need = { romance = true, met = true }, base = -8, acc = { romance = 1, outgoing = 1, audience = -3 }, rep = 10, repFail = 10,
    dur = 2, react = 1.5, pose = "talk", listen = "idle", open = "flirt",
    ok = { mine = { d = 4, l = 1, r = 6 }, theirs = { d = 6, l = 1.5, r = 8 }, social = { 9, 8 }, fun = { 4, 4 },
           pose = { "laugh", "laugh" }, icon = { "soc_flirt", "react_heart" } },
    no = { mine = { d = -2, r = -1 }, theirs = { d = -5, l = -1, r = -3 }, social = { -3, 0 }, pose = { "talk", "idle" },
           icon = { "soc_flirt", "react_no" }, line = "romance_reject", by = "b" },
    cooldown = 180, auto = 0.6, adv = { social = 25, fun = 6 }, aff = { outgoing = 0.8, playful = 0.3 } }

def { id = "sweet_talk", label = "Sweet Talk", cat = "Romance", kind = "romantic", icon = "soc_sweet",
    desc = "Say something tender to someone you have a crush on.",
    need = { romance = true, crush = 25 }, base = 0, acc = { romance = 1.2, audience = -3 }, rep = 12, dur = 2, react = 1.5,
    pose = "talk", listen = "idle", open = "flirt",
    ok = { mine = { d = 5, l = 1, r = 6 }, theirs = { d = 8, l = 2, r = 10 }, social = { 10, 10 },
           pose = { "talk", "laugh" }, icon = { "soc_sweet", "react_heart" } },
    no = { mine = { d = -3, r = -2 }, theirs = { d = -6, l = -1, r = -4 }, social = { -3, 0 }, pose = { "talk", "idle" },
           icon = { "soc_sweet", "react_no" }, line = "romance_reject", by = "b" },
    cooldown = 180, auto = 0.5, adv = { social = 25 } }

def { id = "hold_hands", label = "Hold Hands", cat = "Romance", kind = "romantic", icon = "soc_hands",
    desc = "Reach for their hand. Needs a spark on both sides.",
    need = { romance = true, romanceBoth = 30 }, base = 10, acc = { romance = 1.2, audience = -2 }, rep = 15, dur = 3, react = 1.5,
    pose = "idle", listen = "idle",
    ok = { mine = { d = 6, l = 2, r = 6 }, theirs = { d = 7, l = 2, r = 8 }, social = { 10, 10 }, comfort = { 4, 4 },
           pose = { "idle", "idle" }, icon = { "soc_hands", "react_heart" } },
    no = { mine = { d = -3, r = -2 }, theirs = { d = -6, l = -1, r = -4 }, social = { -3, 0 }, pose = { "idle", "idle" },
           icon = { "soc_hands", "react_no" }, line = "romance_reject", by = "b" },
    cooldown = 180, auto = 0.5, adv = { social = 25, comfort = 6 } }

def { id = "embrace", label = "Romantic Embrace", cat = "Romance", kind = "romantic", icon = "soc_embrace",
    desc = "A long, romantic hug for someone who feels the same way.",
    need = { romance = true, romanceBoth = 45 }, base = 5, acc = { romance = 1.2, audience = -3 }, rep = 15, dur = 2.5, react = 1.5,
    pose = "hug", listen = "hug",
    ok = { mine = { d = 8, l = 2.5, r = 8 }, theirs = { d = 9, l = 3, r = 10 }, social = { 14, 14 }, comfort = { 6, 6 },
           pose = { "hug", "hug" }, icon = { "soc_embrace", "react_heart" } },
    no = { mine = { d = -4, r = -3 }, theirs = { d = -8, l = -2, r = -6 }, social = { -4, 0 }, pose = { "idle", "idle" },
           icon = { "soc_embrace", "react_no" }, line = "romance_reject", by = "b" },
    cooldown = 180, auto = 0.5, adv = { social = 30, comfort = 8 } }

def { id = "kiss", label = "Kiss", cat = "Romance", kind = "romantic", icon = "soc_kiss",
    desc = "The real thing. Only when the feeling is mutual and the friendship is solid.",
    need = { romance = true, romanceBoth = 55, minLife = 35 }, base = 5, acc = { romance = 1.3, audience = -4 }, rep = 15,
    dur = 2, react = 1.5, pose = "kiss", listen = "kiss",
    ok = { mine = { d = 10, l = 3, r = 10 }, theirs = { d = 10, l = 3, r = 12 }, social = { 15, 15 }, fun = { 6, 6 },
           pose = { "kiss", "kiss" }, icon = { "soc_kiss", "react_heart" } },
    no = { mine = { d = -5, r = -4 }, theirs = { d = -10, l = -3, r = -8 }, social = { -5, 0 }, pose = { "idle", "idle" },
           icon = { "soc_kiss", "react_no" }, line = "romance_reject", by = "b" },
    cooldown = 240, auto = 0.4, adv = { social = 32, fun = 8 } }

def { id = "ask_partner", label = "Ask to Go Steady", cat = "Romance", kind = "romantic", icon = "soc_steady",
    desc = "Ask them to be your partner. Needs real love on your side, and they must feel it too.",
    need = { romance = true, crush = 60, minLife = 40, notPartner = true, notTaken = true }, base = -10,
    acc = { romance = 1.5, rel = 1 }, rep = 40, dur = 3, react = 2, pose = "talk", listen = "idle", open = "go_steady",
    ok = { mine = { d = 10, l = 5, r = 8 }, theirs = { d = 12, l = 6, r = 10 }, social = { 15, 15 },
           pose = { "celebrate", "hug" }, icon = { "soc_steady", "react_heart" } },
    no = { mine = { d = -10, l = -3, r = -10 }, theirs = { d = -8, l = -2 }, social = { -8, 0 }, pose = { "cry", "idle" },
           icon = { "soc_steady", "react_no" }, line = "romance_reject", by = "b", upsetA = 240 },
    cooldown = 1440, auto = 0.15, adv = { social = 30 } }

def { id = "break_up", label = "Break Up", cat = "Romance", kind = "hostile", icon = "soc_breakup",
    desc = "End it. Kind people part amicably; it can also turn into a scene.",
    need = { partner = true }, base = 10, acc = { nice = 2, mood = 0.5 }, rep = 60, dur = 3, react = 2,
    pose = "talk", listen = "idle", open = "breakup",
    ok = { mine = { d = -8, l = -10, r = -30 }, theirs = { d = -15, l = -15, r = -30 }, social = { -2, -8 },
           pose = { "talk", "cry" }, icon = { "soc_breakup", "react_sad" }, upset = 1440 },
    no = { mine = { d = -15, l = -15, r = -30, v = 10 }, theirs = { d = -30, l = -25, r = -35, v = 15 }, social = { -4, -12 },
           pose = { "argue", "argue" }, icon = { "soc_breakup", "react_angry" }, line = "argue", by = "b", upset = 1440,
           conflict = true },
    cooldown = 1440 }

---------------------------------------------------------------------------
-- Gifts (items come from the household inventory, SS.Inventory)
def { id = "give_gift", label = "Give a Gift", cat = "Gifts", kind = "kind", icon = "soc_gift",
    desc = "Hand over a gift from the household inventory. They keep it; it lands best if it suits their interests.",
    need = { item = "gift" }, base = 25, acc = { rel = 1, interest = 1.2 }, rep = 25, dur = 2, react = 2,
    pose = "use", listen = "idle", carry = "gift",
    ok = { mine = { d = 4, l = 1 }, theirs = { d = 10, l = 3 }, social = { 6, 10 }, fun = { 0, 6 },
           pose = { "use", "laugh" }, icon = { "soc_gift", "react_gift" }, line = "gift_good", by = "b" },
    no = { mine = { d = -2 }, theirs = { d = -2 }, social = { 3, 1 }, pose = { "use", "idle" },
           icon = { "soc_gift", "react_shrug" }, line = "gift_bad", by = "b" },
    cooldown = 60 }

def { id = "give_flowers", label = "Give Flowers", cat = "Gifts", kind = "kind", icon = "soc_flowers",
    desc = "Present a bunch of flowers from the inventory. Romantic if there's a spark; gardeners love them.",
    need = { item = "flowers" }, base = 30, acc = { rel = 1, romance = 0.6, interest = 0.8 }, rep = 25, dur = 2, react = 2,
    pose = "use", listen = "idle", carry = "flowers",
    ok = { mine = { d = 4, l = 1 }, theirs = { d = 9, l = 2 }, social = { 6, 10 }, pose = { "use", "hug" },
           icon = { "soc_flowers", "react_heart" }, line = "gift_good", by = "b" },
    no = { theirs = { d = -2 }, social = { 3, 0 }, pose = { "use", "idle" }, icon = { "soc_flowers", "react_shrug" },
           line = "gift_bad", by = "b" },
    cooldown = 60 }

---------------------------------------------------------------------------
-- Invitations and visitors (guarded calls into the visitors and outings modules)
def { id = "invite_over", label = "Invite Over Sometime", cat = "Invite", kind = "friendly", icon = "soc_invite",
    desc = "Ask someone from another household to visit later. Friends say yes; acquaintances find excuses.",
    need = { notHousehold = true }, base = 15, acc = { rel = 1.2, outgoing = 2 }, rep = 30, dur = 2, react = 1.5,
    pose = "talk", listen = "idle", open = "invite",
    ok = { mine = { d = 2 }, theirs = { d = 5, l = 1.5 }, social = { 5, 6 }, pose = { "talk", "laugh" },
           icon = { "soc_invite", "react_yes" } },
    no = { theirs = { d = -1 }, social = { 1, 0 }, pose = { "talk", "idle" }, icon = { "soc_invite", "react_no" } },
    cooldown = 720 }

def { id = "invite_outing", label = "Invite on an Outing", cat = "Invite", kind = "friendly", icon = "soc_outing",
    desc = "Go to a community venue together (shops, cafe, park or club).",
    need = { venue = true }, base = 20, acc = { rel = 1.2, outgoing = 2, active = 1 }, rep = 30, dur = 2, react = 1.5,
    pose = "talk", listen = "idle", open = "invite",
    ok = { mine = { d = 3, l = 1 }, theirs = { d = 5, l = 1.5 }, social = { 6, 6 }, pose = { "talk", "celebrate" },
           icon = { "soc_outing", "react_yes" } },
    no = { theirs = { d = -1 }, social = { 1, 0 }, pose = { "talk", "idle" }, icon = { "soc_outing", "react_no" } },
    cooldown = 720 }

def { id = "ask_leave", label = "Ask to Leave", cat = "Visitors", kind = "neutral", icon = "soc_leave",
    desc = "Politely ask a visitor to go home. They go either way; it's how they take it that differs.",
    need = { visitor = true, host = true }, base = 40, acc = { nice = 2, rel = 0.6 }, rep = 60, dur = 1.5, react = 1.5,
    pose = "talk", listen = "idle", open = "ask_leave",
    ok = { theirs = { d = -3, l = -0.5 }, social = { 1, 0 }, pose = { "talk", "greet" }, icon = { "soc_leave", "react_bye" },
           line = "farewell", by = "b" },
    no = { mine = { d = -2 }, theirs = { d = -10, l = -3 }, social = { 0, -3 }, pose = { "talk", "argue" },
           icon = { "soc_leave", "react_angry" }, line = "argue", by = "b" },
    cooldown = 60 }

def { id = "group_chat", label = "Start a Group Chat", cat = "Group", kind = "friendly", icon = "soc_group",
    desc = "Gather the people nearby into one conversation. Everyone can join, react and drift off.",
    base = 20, acc = { outgoing = 2 }, rep = 20, dur = 2, react = 1.5, pose = "talk", listen = "idle", open = "smalltalk",
    ok = { mine = { d = 3, l = 1 }, theirs = { d = 4, l = 1 }, social = { 8, 8 }, pose = { "talk", "talk" },
           icon = { "soc_group", "react_yes" } },
    no = { theirs = { d = -1 }, social = { 1, 0 }, pose = { "talk", "idle" }, icon = { "soc_group", "react_shrug" } },
    cooldown = 60, auto = 0.5, adv = { social = 30 }, aff = { outgoing = 1.2 } }

def { id = "join_group", label = "Join the Conversation", cat = "Group", kind = "friendly", icon = "soc_group",
    desc = "Walk up to a conversation already going on and join in. Awkward if they wanted privacy.",
    need = { session = true }, base = 20, acc = { outgoing = 1 }, rep = 20, dur = 1.5, react = 1.5,
    pose = "greet", listen = "idle", open = "group_join",
    ok = { mine = { d = 3, l = 1 }, theirs = { d = 3, l = 1 }, social = { 8, 4 }, pose = { "greet", "greet" },
           icon = { "react_hello", "react_hello" } },
    no = { mine = { d = -2 }, theirs = { d = -3 }, social = { -2, 0 }, pose = { "greet", "idle" },
           icon = { "react_hello", "react_awkward" } },
    cooldown = 60, auto = 0.8, adv = { social = 28 }, aff = { outgoing = 1 } }

---------------------------------------------------------------------------
-- Children and family
def { id = "play_with", label = "Play With", cat = "Kids", kind = "fun", icon = "soc_play",
    desc = "Play a made-up game with a child.",
    whom = "child", base = 30, acc = { playful = 2 }, rep = 12, dur = 5, react = 1.5, pose = "play", listen = "play", open = "kid_play",
    ok = { mine = { d = 6, l = 2 }, theirs = { d = 7, l = 2.5 }, social = { 8, 10 }, fun = { 10, 16 },
           pose = { "laugh", "laugh" }, icon = { "soc_play", "react_laugh" } },
    no = { theirs = { d = -2 }, social = { 2, 0 }, pose = { "idle", "idle" }, icon = { "soc_play", "react_no" } },
    cooldown = 60, auto = 0.9, adv = { fun = 25, social = 18 }, aff = { playful = 1, nice = 0.3 } }

def { id = "tickle", label = "Tickle", cat = "Kids", kind = "fun", icon = "soc_tickle",
    desc = "Tickle a child you know well. Grumpy children do not appreciate it.",
    whom = "child", need = { closeOrFamily = 10 }, base = 25, acc = { playful = 3 }, rep = 12, dur = 1.5, react = 1.5,
    pose = "play", listen = "laugh", open = "kid_tickle",
    ok = { mine = { d = 5, l = 1.5 }, theirs = { d = 6, l = 2 }, social = { 6, 6 }, fun = { 10, 14 },
           pose = { "laugh", "laugh" }, icon = { "soc_tickle", "react_laugh" } },
    no = { mine = { d = -2 }, theirs = { d = -5, l = -1 }, social = { 0, -2 }, fun = { 2, -5 },
           pose = { "play", "argue" }, icon = { "soc_tickle", "react_angry" } },
    cooldown = 60, auto = 0.7, adv = { fun = 20, social = 10 }, aff = { playful = 1 } }

def { id = "read_to", label = "Read a Story", cat = "Kids", kind = "kind", icon = "soc_book",
    desc = "Read to a child. Needs a book in the household or a bookshelf on the lot. Teaches a little.",
    who = "adult", whom = "child", need = { book = true }, base = 35, acc = { playful = -1, active = -1 }, rep = 15,
    dur = 6, react = 1.5, pose = "read", listen = "idle", carry = "book", open = "read_aloud",
    ok = { mine = { d = 5, l = 2 }, theirs = { d = 7, l = 3 }, social = { 6, 10 }, fun = { 6, 12 },
           pose = { "read", "laugh" }, icon = { "topic_books", "react_heart" } },
    no = { theirs = { d = -2 }, social = { 2, 0 }, fun = { 0, -2 }, pose = { "read", "idle" }, icon = { "topic_books", "react_bored" } },
    cooldown = 120, auto = 0.6, adv = { social = 18, fun = 10 }, aff = { nice = 0.6, playful = -0.2 } }

def { id = "scold", label = "Scold", cat = "Kids", kind = "hostile", icon = "soc_scold",
    desc = "Tell off a child in your care. Fair after misbehaviour; hurtful when it isn't.",
    who = "adult", whom = "child", need = { guardianOf = true }, base = 25, acc = { nice = 2 }, rep = 20, dur = 2, react = 2,
    pose = "argue", listen = "idle", open = "scold",
    ok = { mine = { d = -1 }, theirs = { d = -4 }, social = { 2, 0 }, pose = { "argue", "idle" },
           icon = { "soc_scold", "react_sorry" } },
    no = { mine = { d = -3 }, theirs = { d = -10, l = -3 }, social = { 0, -4 }, fun = { 0, -6 }, pose = { "argue", "cry" },
           icon = { "soc_scold", "react_sad" }, upset = 60 },
    cooldown = 120, auto = 0.3, adv = { social = 6 }, aff = { nice = -0.5, neat = 0.5 } }

def { id = "praise", label = "Praise", cat = "Kids", kind = "kind", icon = "soc_praise",
    desc = "Tell a child they did well. Almost always welcome.",
    who = "adult", whom = "child", base = 40, rep = 20, dur = 1.5, react = 1.5, pose = "talk", listen = "idle", open = "compliment",
    ok = { mine = { d = 4, l = 1 }, theirs = { d = 8, l = 3 }, social = { 4, 10 }, fun = { 0, 4 },
           pose = { "talk", "celebrate" }, icon = { "soc_praise", "react_star" } },
    no = { theirs = { d = -1 }, pose = { "talk", "idle" }, icon = { "soc_praise", "react_shrug" } },
    cooldown = 60, auto = 0.8, adv = { social = 18 }, aff = { nice = 1 } }

def { id = "help_homework", label = "Help With Homework", cat = "Kids", kind = "kind", icon = "soc_homework",
    desc = "Sit with a child in your family and work through their homework. Teaches logic; patience required.",
    who = "adult", whom = "child", need = { guardianOf = true }, base = 30, acc = { playful = -2 }, rep = 20, dur = 8, react = 1.5,
    pose = "talk", listen = "read", open = "homework", skill = { logic = 0.1 },
    ok = { mine = { d = 4, l = 1.5 }, theirs = { d = 6, l = 2.5 }, social = { 6, 8 }, fun = { 0, -2 },
           pose = { "talk", "celebrate" }, icon = { "soc_homework", "react_idea" }, line = "school_good", by = "b" },
    no = { mine = { d = -2 }, theirs = { d = -4 }, social = { 2, -2 }, fun = { 0, -6 }, pose = { "talk", "argue" },
           icon = { "soc_homework", "react_angry" }, line = "school_bad", by = "b" },
    cooldown = 240, auto = 0.4, adv = { social = 12 }, aff = { neat = 0.4, playful = -0.4 } }

---------------------------------------------------------------------------
SS.Socials = { list = L, byId = {}, byIid = {} }
-- Menu order of categories.
SS.Socials.CATS = { "Hello", "Talk", "Fun", "Games", "Kind", "Affection", "Romance", "Gifts", "Invite", "Group",
    "Family", "Kids", "Visitors", "Mean" }
for n, d in ipairs(L) do
    d.order = n
    d.iid = "soc_" .. d.id
    if d.cat == "Romance" then d.who, d.whom = d.who or "adult", d.whom or "adult" end
    d.who, d.whom = d.who or "any", d.whom or "any"
    d.need = d.need or {}
    d.acc, d.accA = d.acc or {}, d.accA or {}
    d.dur, d.react = d.dur or 2, d.react or 1.5
    d.rep, d.repFail = d.rep or 10, d.repFail or 0
    d.cooldown = d.cooldown or 60
    SS.Socials.byId[d.id] = d
    SS.Socials.byIid[d.iid] = d
end

-- Every balloon icon the social module uses (art requests list these; missing ones draw a placeholder).
SS.Socials.ICONS = {
    "react_hello", "react_bye", "react_awkward", "react_shrug", "react_yes", "react_no", "react_question", "react_heart",
    "react_laugh", "react_bored", "react_idea", "react_angry", "react_sad", "react_whisper", "react_trophy", "react_groan",
    "react_suspicious", "react_star", "react_gift", "react_sorry", "react_handshake", "react_jealous", "react_embarrassed",
    "react_mess", "react_tired",
    "soc_hello", "soc_wave", "soc_handshake", "soc_hug", "soc_bye", "soc_talk", "soc_question", "soc_debate", "soc_gossip",
    "soc_complain", "soc_story", "soc_boast", "soc_joke", "soc_pun", "soc_tease", "soc_impression", "soc_game", "soc_tag",
    "soc_guess", "soc_compliment", "soc_flatter", "soc_comfort", "soc_sorry", "soc_thanks", "soc_highfive", "soc_backrub",
    "soc_pat", "soc_argue", "soc_insult", "soc_chores", "soc_flirt", "soc_sweet", "soc_hands", "soc_embrace", "soc_kiss",
    "soc_steady", "soc_breakup", "soc_gift", "soc_flowers", "soc_invite", "soc_outing", "soc_leave", "soc_group",
    "soc_play", "soc_tickle", "soc_book", "soc_scold", "soc_praise", "soc_homework",
    -- caption icons for situations other modules call (Data/Lines.lua situation meta)
    "bubble", "react_think", "react_book", "react_school", "react_fire", "react_food", "react_money", "react_work",
    "react_phone", "react_ghost",
}
