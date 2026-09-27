-- Authored lines (social module). All text is original. Sim/Lines.lua parses this table once at
-- load, checks every condition against real state and fills the slots.
--
-- situations[name] = { label, icon, important, journal, gap, defaultRole }
--   label      shown in the line log and journal detail
--   icon       balloon icon when a module calls SS.Lines.Speak
--   important  emergencies, work, money trouble, death: bypass the hourly cap (never the no-repeat)
--   journal    also write the caption to the household journal
--   gap        minutes between two captions of this situation in one household (default 12)
--   defaultRole  the role a caller that passes none is speaking in (e.g. "listener" for reactions)
-- lines = { { id, s = situation, t = text, c = "conditions", d = "expandable detail", w = weight } }
--   conditions are space-separated tokens on context keys (SS.Lines.CTX_KEYS):
--     key  !key  key=value  key~=value  key>=n  key<=n  key>n  key<n
--   slots {speaker} {name} {host} {other} {topic} {obj} {item} {amount} {meal} {job} {skill} {pet} {plant}
--     {deceased} {place} {holder} {subject} {grade} {count} {days} {mess}; a line whose slot has
--     no value in the context is never chosen.
-- Line ids are "<situation>_<n>" in authoring order: append new lines at the end of a situation
-- so saved no-repeat memories keep pointing at the same text.
local _, SS = ...

local situations, lines = {}, {}
SS.LineData = { situations = situations, lines = lines }

local cur, n
local function sit(name, meta)
    situations[name] = meta
    cur, n = name, 0
end
local function ln(text, cond, detail, w)
    n = n + 1
    lines[#lines + 1] = { id = cur .. "_" .. n, s = cur, t = text, c = cond, d = detail, w = w }
end

---------------------------------------------------------------------------
-- Everyday conversation
---------------------------------------------------------------------------
sit("greet", { label = "Greeting", icon = "react_hello", gap = 4 })
ln("Hi, I'm {speaker}. I live around here, mostly on purpose.", "role=speaker age=adult")
ln("Hello! I've seen you around. From a normal distance, I promise.", "role=speaker")
ln("Oh. Hello. Hi. I'm {speaker}. That's the whole introduction.", "role=speaker outgoing<=3",
    "{speaker} is shy and had been rehearsing this in their head for a while.")
ln("{speaker}! Pleased to meet you. Firm handshake, open face, that's me.", "role=speaker outgoing>=7")
ln("Hi! I'm {speaker}. Do you like frogs? I'm deciding who my friends are.", "role=speaker age=child")
ln("Nice to meet you, {speaker}. That's me. I mean, I'm {speaker}. Hello.", "role=listener outgoing<=4")
ln("Lovely to meet you. You seem normal. How refreshing.", "role=listener nice>=6")
ln("Right. Hi. I'll try to remember your face.", "role=listener nice<=3")
ln("Hello yourself! I'm {speaker}. Welcome to the street.", "role=listener !guest")
ln("Hello there! Good to see a friendly face.", "!role")
ln("Morning, {other}! Lovely day for it, apparently.", "!role passing hour<12")
ln("Hi, {other}! Can't stop, but hi! Consider yourself greeted.", "!role passing")
ln("Hello, everyone! I brought my party face.", "!role party")
ln("Thanks for having me, {host}. I've been looking forward to this all week.", "!role party !isHost")

sit("farewell", { label = "Goodbye", icon = "react_bye", gap = 4 })
ln("Right, I'd better be off before I get comfortable.", "role=speaker")
ln("Bye! Don't do anything I'd have to hear about.", "role=speaker playful>=5")
ln("Goodnight! Sleep well, or at least efficiently.", "hour>=20")
ln("See you around, {other}. Probably by the bins.", "role=speaker rel>=10")
ln("Say no more. I was leaving anyway. Eventually.", "role=listener guest",
    "{speaker} took the hint, and took their time.")
ln("Fine, fine. I know when a welcome's been worn right through.", "role=listener guest nice<=4")
ln("Thanks for having me! I'll let myself out. Slowly.", "guest nice>=5")
ln("Bye, then. Mind the step on the way out.", "!guest")
ln("Off I go. Thanks, everyone.", "!role guest")
ln("All done! Ring us if it happens again. It won't. Probably.", "!role reason=done")
ln("Right you are. I'll see myself out.", "!role reason=dismissed")
ln("Nothing here needs me after all. Lucky you.", "!role reason=nowork")
ln("Delivered, signed for, and gone. Enjoy!", "!role reason=delivered")

sit("smalltalk", { label = "Small talk", icon = "bubble", gap = 6 })
ln("Weather's been very... present lately.", "topic=weather role=speaker")
ln("Looks like rain. Or doesn't. The sky won't commit these days.", "topic=weather role=speaker")
ln("Did you hear the council is redoing the road markings? Again?", "topic=townnews role=speaker")
ln("Apparently the corner shop is getting a second corner.", "topic=townnews role=speaker")
ln("So! How about that... general situation.", "role=speaker outgoing<=4",
    "{speaker} had nothing in particular to say and said it bravely.")
ln("Busy week? Mine's been a week. That's all I can say for it.", "role=speaker")
ln("Honestly? Pretty good. Something went right and I'm suspicious.", "role=listener mood>=20")
ln("Fine. Normal. One of those days you forget by dinner.", "role=listener mood<20 mood>=-15")
ln("Everyone come over here, this corner has the good conversation.", "role=speaker witnesses>=2")
ln("{other}! How have you been? No, really, how?", "!role !phone")
ln("Hello, {other}. Just ringing to see what's new.", "!role phone")
ln("It's me! Nothing important. I just fancied a chat.", "!role phone")
ln("Nice place, {other}. It suits you. Cosy, but in a good way.", "!role guest !phone")

sit("ask_day", { label = "Asking about the day", icon = "bubble", gap = 6 })
ln("How was your day? The honest version, please.", "role=speaker")
ln("So, what's new with you? Anything? Tell me anything.", "role=speaker outgoing>=6")
ln("You look like you've had a day. Want to talk about it?", "role=speaker otherMood<-10")
ln("How's school? Did anybody do anything outrageous?", "role=speaker otherAge=child")

sit("topic_love", { label = "Talking about an interest", icon = "bubble", gap = 5 })
ln("Can I tell you about {topic}? Too late, I've started.", "role=speaker myInterest>=7")
ln("I've been reading about {topic} all week. I think it's reading me back.", "role=speaker myInterest>=8")
ln("{topic} is the best thing people ever came up with. Fight me. Politely.", "role=speaker myInterest>=7 playful>=6")
ln("Okay, but have you ever really, properly thought about {topic}?", "role=speaker myInterest>=7")
ln("I've got a new theory about {topic}. It's mostly enthusiasm.", "role=speaker myInterest>=7",
    "{speaker} is keen on {topic} and cannot hide it.")
ln("I'm slowly getting into {topic}. Slowly, and then all at once.", "role=speaker myInterest>=5 myInterest<=6")
ln("Wait, you like {topic} too? Sit down, we'll be here a while.", "role=listener myInterest>=7",
    "They share a love of {topic}.")
ln("Finally, somebody who understands {topic}!", "role=listener myInterest>=8")
ln("I don't know much about {topic}, but you make it sound fun.", "role=listener myInterest>=4 myInterest<=6")
ln("Keep going, I'm genuinely interested. That's not a thing I say.", "role=listener nice<=4 myInterest>=6")
ln("Ooh, tell me more about {topic}! Is it hard? Can kids do it?", "role=listener age=child myInterest>=5")

sit("topic_hate", { label = "A topic they can't stand", icon = "react_bored", gap = 5 })
ln("Is this still about {topic}? It's been about {topic} for a while.", "role=listener myInterest<=3",
    "{speaker} does not care for {topic}, and it has been a long few minutes.")
ln("I'll be honest: {topic} is my least favourite noise.", "role=listener myInterest<=2")
ln("You clearly love {topic}. I clearly need to sit somewhere else.", "role=listener myInterest<=2 interest>=7",
    "{other} loves {topic}. {speaker} really, really doesn't.")
ln("Every word about {topic} takes a year off my life. Not in a good way.", "role=listener myInterest<=2")
ln("Mm. Yes. {topic}. Fascinating. Is that the time?", "role=listener myInterest<=3 nice>=5")
ln("Please stop saying {topic} at me.", "role=listener myInterest<=2 nice<=4")
ln("I've never been so awake and so bored at the same time.", "role=listener myInterest<=3")
ln("Can we talk about literally anything else? Socks? Soup?", "role=listener myInterest<=3 playful>=5")

---------------------------------------------------------------------------
-- Fun
---------------------------------------------------------------------------
sit("joke_good", { label = "A joke lands", icon = "react_laugh", gap = 4 })
ln("Ha! Okay, that one got me.", "role=listener")
ln("I'm stealing that. You'll never hear it again.", "role=listener playful>=5")
ln("Stop, I'll snort, and then we'll both have to live with it.", "role=listener playful>=6")
ln("That's actually funny. I'm as surprised as you are.", "role=listener nice<=4")
ln("Hee hee! Tell it again! Tell it again!", "role=listener age=child")
ln("Very good. I'll laugh again later when I fully get it.", "role=listener playful<=4")
ln("You should do this for money. Or at least at weddings.", "role=listener rel>=20")
ln("Oh, that's dreadful. I love it.", "role=listener nice>=5")

sit("joke_bad", { label = "A joke falls flat", icon = "react_awkward", gap = 4 })
ln("That was funnier in my head. It had a crowd in there.", "role=speaker",
    "An awkward pause followed. Somebody coughed.")
ln("...and that's where the laugh goes. Just there. In the silence.", "role=speaker",
    "The silence lasted long enough to have a personality.")
ln("Tough crowd. Large, too. Great.", "role=speaker witnesses>=2",
    "{speaker} bombed in front of {witnesses} onlookers.")
ln("Okay. Noted. Retiring that one with full honours.", "role=speaker")
ln("No? Nothing? I'll workshop it.", "role=speaker playful>=7")
ln("You told that one already. It hasn't aged well since.", "role=listener count>=1",
    "{other} has now tried this joke on {speaker} more than once.")
ln("I see what you did there. I wish I didn't.", "role=listener")
ln("Was that the joke? The whole joke?", "role=listener nice<=3")
ln("Heh. Mm. That was a sentence, definitely.", "role=listener nice>=7")
ln("Same joke, same face. Mine, I mean. This face.", "role=listener count>=2")

sit("story", { label = "Telling a story", icon = "bubble", gap = 5 })
ln("So there I was, halfway up a ladder, holding a sandwich...", "role=speaker")
ln("This one time at a {topic} thing, a man lost a shoe. It gets better.", "role=speaker myInterest>=5")
ln("Remember that holiday when it rained so hard the ducks went indoors?", "role=speaker family")
ln("Remember the day we met? You held the door. I walked into it.", "role=speaker rel>=40")
ln("True story. Mostly true. The important bits are true.", "role=speaker playful>=6")
ln("When I was your age we had to walk to school. Both ways. Uphill.", "role=speaker age=adult otherAge=child")

sit("gossip", { label = "Gossip", icon = "react_whisper", gap = 8 })
ln("Don't tell anyone, but {subject} alphabetises their snacks.", "role=speaker")
ln("You didn't hear this from me: {subject} practises dance moves in the garden.", "role=speaker")
ln("So, {subject}. Interesting person. Very... interesting. You know.", "role=speaker")
ln("I heard {subject} sent a thank-you note for a thank-you note.", "role=speaker nice>=4")
ln("Word is {subject} fell asleep at their own birthday.", "role=speaker")
ln("I'm not one to gossip, but I have been saving this all day.", "role=speaker")
ln("Guess what I heard about the new neighbours. Go on, guess.", "!role phone")
ln("I shouldn't say this on the phone, but I'm going to.", "!role phone")
ln("{other}, you will never believe whose fence is purple now.", "!role phone")

sit("overheard", { label = "Overhearing gossip", icon = "react_angry", gap = 6 })
ln("I can hear you, you know!", "role=listener")
ln("Talking about me? I'm flattered. And furious.", "role=listener nice>=4")
ln("Say it to my face, {other}. Go on.", "role=listener nice<=4")
ln("I'm standing right here. I have ears. Two of them.", "role=listener")

sit("compliment", { label = "Compliment", icon = "react_heart", gap = 5 })
ln("You have a great laugh. It makes everyone else's sound tired.", "role=speaker")
ln("You always know exactly what to say. It's annoying, in a good way.", "role=speaker")
ln("Have you done something different? Whatever it is, keep doing it.", "role=speaker")
ln("You're one of my favourite people, and I've met loads.", "role=speaker rel>=30")
ln("That outfit is doing a lot of work, and it's winning.", "role=speaker playful>=4")
ln("You're... not the worst. That's high praise from me.", "role=speaker nice<=3",
    "{speaker} doesn't hand out compliments. This counts as one.")
ln("Look at you! You're getting so clever I'll need to study to keep up.", "role=speaker age=adult otherAge=child")
ln("I'm proud of you. Genuinely, loudly proud.", "role=speaker age=adult otherAge=child family")
ln("You're my best friend. Don't tell the others.", "role=speaker age=child otherAge=child rel>=30")

sit("thanks", { label = "Thanks", icon = "react_heart", gap = 6 })
ln("Thanks for earlier. You made a rotten day much less rotten.", "role=speaker")
ln("I owe you one. Possibly two. I'm keeping count.", "role=speaker playful>=5")
ln("That was really kind of you. I noticed.", "role=speaker")

sit("boast", { label = "Boasting", icon = "react_star", gap = 8 })
ln("Did I mention I'm basically an expert at {skill} now? Well, I am.", "role=speaker")
ln("They call me the best {job} on the street. 'They' is mostly me.", "role=speaker")
ln("We've got {amount} in the bank. Not that I'm counting. I'm counting.", "role=speaker",
    "The household really does have {amount}.")
ln("I don't like to brag, but I'm incredible.", "role=speaker")
ln("I once parallel parked first time. Witnesses wept.", "role=speaker age=adult")
ln("Some of us are just naturally gifted. I'm some of us.", "role=speaker outgoing>=6")
ln("I can do a cartwheel. Nearly. Almost nearly.", "role=speaker age=child")

sit("boast_undercut_mess", { label = "Boast undercut by mess", icon = "react_mess", gap = 6 })
ln("Impressive. Is that why there's a {mess} right behind you?", "role=listener mess>=1",
    "{other} was boasting a few steps from a {mess}.")
ln("Very successful. Also, your {mess} is staring at me.", "role=listener mess>=1")
ln("Great. For your next trick, maybe tidy up?", "role=listener mess>=2")
ln("Mm-hm. Tell me more, over the smell.", "role=listener mess>=3")
ln("You'd be more convincing standing somewhere cleaner.", "role=listener mess>=2")
ln("Living the dream, I see. The dream has crumbs.", "role=listener mess>=2 playful>=5")

sit("complain", { label = "Complaining", icon = "react_sad", gap = 8 })
ln("Everything's gone wrong today. Even the things that were already wrong.", "role=speaker mood<5")
ln("My back hurts, my feet hurt, and my patience has left the building.", "role=speaker age=adult")
ln("Is it just me, or is everything slightly worse than it should be?", "role=speaker")
ln("I'm tired. Not sleepy. Tired. Philosophically.", "role=speaker")
ln("Honestly, this whole place is getting me down.", "role=speaker roomScore<=-30",
    "The room {speaker} is standing in really is grim.")
ln("Don't ask. No, do ask. It's been awful.", "role=listener mood<-15")
ln("Where do I start? Actually, don't let me start.", "role=listener mood<-15")
ln("This {obj} is fighting back. Round two.", "reason=repair_retry")
ln("Nearly had it. The {obj} had other ideas.", "reason=repair_retry")
ln("Hang on, the {obj} and I are still negotiating.", "reason=repair_retry")

sit("tease", { label = "Teasing", icon = "react_laugh", gap = 6 })
ln("Nice hair. Did that happen on purpose?", "role=speaker")
ln("Look who's up! Only took you all morning.", "role=speaker hour>=9 hour<=12")
ln("Is that a new walk, or are your shoes on the wrong feet?", "role=speaker")
ln("Oh no, it's the famous {other}. Everybody hide.", "role=speaker rel>=0")
ln("Guess who: 'Well, actually...' It's {subject}! Obviously.", "role=speaker")
ln("I'm doing my {subject} face. Is it working?", "role=speaker playful>=5")

sit("game_thumb", { label = "Thumb war", icon = "react_trophy", gap = 6 })
ln("One, two, three, four, I declare a thumb war!", "role=speaker")
ln("Thumb war. Loser does the washing up.", "role=speaker age=adult")
ln("My thumb has been training for this its whole life.", "role=speaker playful>=5")

sit("game_tag", { label = "Tag", icon = "react_laugh", gap = 6 })
ln("Tag! You're it! No take-backs!", "role=speaker")
ln("Bet you can't catch me! Bet you can't! Bet you...", "role=speaker age=child")
ln("Tag. I'm old, so you have to run slowly.", "role=speaker age=adult")

sit("game_guess", { label = "Guessing game", icon = "react_think", gap = 6 })
ln("I'm thinking of something. It's round. Mostly round.", "role=speaker")
ln("Twenty questions. Question one: are you ready to lose?", "role=speaker playful>=5")
ln("Guess what I had for breakfast. Wrong. It was cake.", "role=speaker playful>=6")

---------------------------------------------------------------------------
-- Kindness, conflict, affection
---------------------------------------------------------------------------
sit("argue", { label = "Argument", icon = "react_angry", gap = 3 })
ln("You always do this, and I always notice.", "role=speaker")
ln("No, you listen. I've been waiting all day to say this.", "role=speaker")
ln("Here's a thought: what if you were wrong? Because you are.", "role=speaker nice<=3")
ln("Every time I see you, I remember why I stopped seeing you.", "role=speaker rel<=-20")
ln("We need to talk, and by talk I mean I talk.", "role=speaker partner")
ln("Oh, that's rich, coming from you.", "role=listener")
ln("Excuse me? Excuse me?!", "role=listener")
ln("Say that again. Slower. So I can enjoy being right.", "role=listener nice<=3")
ln("I'm not doing this with you right now.", "role=listener nice>=7")
ln("Wow. Okay. Wow.", "role=listener")
ln("You don't get to be upset. I'm the upset one!", "role=listener partner")

sit("scold", { label = "Telling off", icon = "react_angry", gap = 6 })
ln("Hey! We don't do that in this house.", "role=speaker")
ln("Right, young {other}. What have you got to say for yourself?", "role=speaker")
ln("I'm not angry. I'm disappointed, which is worse, apparently.", "role=speaker nice>=5")
ln("One more time and there's no pudding. I mean it this time.", "role=speaker")

sit("insult", { label = "Insult", icon = "react_angry", gap = 5 })
ln("You have all the charm of a damp sock.", "role=speaker")
ln("I've met houseplants with better conversation.", "role=speaker")
ln("If I wanted your opinion, I'd have asked someone else's.", "role=speaker nice<=4")
ln("{topic}? Of course you like {topic}. It explains a lot.", "role=speaker interest>=6",
    "{other} really does love {topic}, which is what makes it sting.")
ln("Who even likes {topic}? Oh, right. You.", "role=speaker interest>=6")
ln("You smell like old cheese!", "role=speaker age=child")

sit("apologize", { label = "Apology", icon = "react_sorry", gap = 6 })
ln("I'm sorry. I was wrong, and also loud, which didn't help.", "role=speaker")
ln("About before. I didn't mean it. Well, not the bad parts.", "role=speaker")
ln("Can we start over? I'll go first: sorry.", "role=speaker")
ln("I've been thinking about what I said, and I'd like to un-say it.", "role=speaker nice>=5")
ln("Sorry. I didn't mean to. Mostly.", "role=speaker age=child")
ln("Fine. Sorry. There. Happy?", "role=speaker nice<=3")

sit("comfort", { label = "Comfort", icon = "react_heart", gap = 6 })
ln("Hey. Whatever it is, you don't have to carry it alone.", "role=speaker")
ln("Come here. It's going to be all right, and if it isn't, I'm around.", "role=speaker rel>=20")
ln("Oh no. Sit down. Tell me everything, or nothing. Whatever helps.", "role=speaker otherMood<-40")
ln("Hey, champ. Deep breath. We'll sort it out together.", "role=speaker age=adult otherAge=child")
ln("Oh, that sounds rotten. I'm sorry.", "role=listener")
ln("You poor thing. Do you want tea, a hug, or someone to blame?", "role=listener nice>=6")

sit("chores_argument", { label = "Chores argument", icon = "react_mess", gap = 6 })
ln("Whose turn is it to deal with the {obj}? Hint: not mine.", "role=speaker",
    "There really is a {obj} waiting to be dealt with.")
ln("That {obj} has been there so long it's getting post.", "role=speaker")
ln("I did the last three. You're welcome, by the way.", "role=speaker")
ln("I'm not asking you to be tidy. Just less of a weather system.", "role=speaker neat>=7")
ln("Fine. FINE. I'll do it. Watch me do it, loudly.", "role=listener outcome=accepted")
ln("I was going to do it! Eventually! It's on my list!", "role=listener outcome=rejected")
ln("It's not a mess, it's a system. Just not your system.", "role=listener neat<=3 outcome=rejected")
ln("All right, all right. Where's the sponge?", "role=listener nice>=6 outcome=accepted")

sit("flirt", { label = "Flirting", icon = "react_heart", gap = 5 })
ln("Is it warm in here, or is it just you standing near me?", "role=speaker")
ln("I had a whole clever line planned, and then you smiled.", "role=speaker")
ln("You're the best part of this street. And I've been to the bakery.", "role=speaker")
ln("Do you believe in love at first sight, or should I walk past again?", "role=speaker playful>=6")
ln("You look really nice today. That's all. I'll go. Or stay.", "role=speaker outgoing<=4")
ln("Still you. Still my favourite.", "role=speaker partner")

sit("go_steady", { label = "Asking to go steady", icon = "react_heart", gap = 30, journal = true })
ln("I think I love you. Want to make this official?", "role=speaker")
ln("So, you and me. Properly. What do you say?", "role=speaker")
ln("I've been thinking. I'd like us to be a real couple.", "role=speaker outgoing<=5")

sit("romance_reject", { label = "Romantic rejection", icon = "react_no", gap = 5, defaultRole = "listener" })
ln("Oh! Um. I think you've got the wrong idea. About us.", "role=listener",
    "{other} misread the moment. Badly.")
ln("That's sweet. No. But sweet.", "role=listener nice>=5")
ln("Let's pretend that didn't happen. I'm already pretending.", "role=listener")
ln("Absolutely not. Where did that come from?", "role=listener nice<=3")
ln("Not right now, love. I'm not in the mood.", "role=listener partner")
ln("I like you, just... not like that.", "role=listener rel>=30 !partner")
ln("In front of everyone? Really?", "role=listener witnesses>=1",
    "{speaker} was mortified to be put on the spot with people watching.")

sit("breakup", { label = "Break-up", icon = "react_sad", gap = 30, journal = true })
ln("I think we should stop seeing each other. Romantically. And maybe at all.", "role=speaker")
ln("This isn't working, and I think we both know it.", "role=speaker nice>=4")
ln("It's not you. Actually, it's quite a lot you.", "role=speaker nice<=3")
ln("I need some space. Quite a lot of it, actually.", "role=speaker")

sit("jealous", { label = "Jealousy", icon = "react_jealous", gap = 5, journal = true })
ln("{subject}? Really? I saw that, you know.", "role=speaker")
ln("Oh, don't mind me. I'll just stand here being your partner.", "role=speaker partner",
    "{speaker} watched their partner get cosy with {subject}.")
ln("What exactly was that with {subject}?", "role=speaker")
ln("I turn my back for five minutes and you're cosying up to {subject}.", "role=speaker")
ln("You and {subject}. We are going to talk. Loudly.", "role=speaker nice<=3")

sit("gift_good", { label = "A welcome gift", icon = "react_gift", gap = 6, defaultRole = "listener" })
ln("For me? You shouldn't have. But you did! Thank you!", "role=listener")
ln("A {item}! How did you know?", "role=listener")
ln("I love it. It's going somewhere everyone can see it.", "role=listener")
ln("{item}? You know me far too well.", "role=listener myInterest>=7",
    "{speaker} adores {topic}, and the gift shows {other} noticed.")
ln("Flowers! Nobody's given me flowers since... ever.", "role=listener itemKind=flowers")
ln("These are lovely. They smell like a good mood.", "role=listener itemKind=flowers nice>=5")

sit("gift_bad", { label = "An unwelcome gift", icon = "react_awkward", gap = 6, defaultRole = "listener" })
ln("Oh. A {item}. That's... a thing I own now.", "role=listener")
ln("Thank you? I'll treasure it. In a drawer.", "role=listener")
ln("A {item}. For me. Because of my famous love of {topic}?", "role=listener myInterest<=2",
    "{speaker} really does not care for {topic}.")
ln("Did you get this for free?", "role=listener nice<=3")
ln("I don't want anything from you.", "role=listener rel<=-30")
ln("Flowers? From you? Is this a joke?", "role=listener itemKind=flowers rel<=0")

sit("gift_handback", { label = "A gift handed back", icon = "react_awkward", gap = 6 })
ln("That's so kind. But honestly, we've no room left for one more thing. You keep it.", "role=listener",
    "There was nowhere to keep it, so {speaker} gave it back with thanks.")
ln("I'd love to, but I'd have nowhere to put it. Hang on to it for me?", "role=listener nice>=5")
ln("Where would I even put that? No. Thank you. No.", "role=listener nice<=4")
ln("Oh, you're sweet. My hands are full, though. Literally everywhere.", "role=listener playful>=6")

sit("invite", { label = "Invitation", icon = "react_hello", gap = 10 })
ln("Want to come over some time? We have chairs and everything.", "role=speaker !guest")
ln("A few of us are heading out later. Fancy it?", "role=speaker outgoing>=5")
ln("You should come round! I'll pretend I can cook.", "role=speaker !guest")

sit("group_join", { label = "Joining a group", icon = "bubble", gap = 6 })
ln("Mind if I join? I heard laughing and got jealous.", "role=speaker")
ln("What are we talking about? Wait, let me guess. Me?", "role=speaker playful>=5")
ln("Room for one more? I'm small. Emotionally.", "role=speaker")
ln("Hi. I'll just... stand here. Near you all.", "role=speaker outgoing<=3")

sit("ask_leave", { label = "Asking a guest to leave", icon = "react_bye", gap = 6 })
ln("It's getting late, and I'm getting into my pyjamas.", "role=speaker hour>=20")
ln("This has been lovely. It has also been long.", "role=speaker")
ln("I'd love you to stay, but I'd love it more if you went.", "role=speaker nice<=4")
ln("Right! Well! Don't let me keep you. Please.", "role=speaker")
ln("Sorry, we've an early start. Let's do this again soon?", "role=speaker nice>=7")
ln("It's getting late. Not that I'm hinting. I'm hinting.", "!role")
ln("Thanks for coming! The door's this way. It opens outwards.", "!role")
ln("We've loved having you. We'd also love to go to bed.", "!role hour>=21")

sit("advice", { label = "Asking for advice", icon = "react_think", gap = 8 })
ln("Can I ask you something? You always know what to do.", "role=speaker")
ln("I need your advice. My own has been terrible lately.", "role=speaker")
ln("What would you do if you were me? Apart from panic.", "role=speaker age=child")

---------------------------------------------------------------------------
-- Children
---------------------------------------------------------------------------
sit("kid_play", { label = "Playing", icon = "react_laugh", gap = 6 })
ln("Want to play? I've got a game with loads of rules I'll make up.", "role=speaker age=child")
ln("Let's play! You be the dragon. I'll be the other dragon.", "role=speaker")
ln("The floor is lava! It's always lava! Go!", "role=speaker playful>=5")

sit("kid_tickle", { label = "Tickling", icon = "react_laugh", gap = 6 })
ln("Here comes the tickle monster!", "role=speaker")
ln("Where's the ticklish spot? Is it here? Is it HERE?", "role=speaker")
ln("No laughing allowed. Oh dear. Somebody's laughing.", "role=speaker playful>=5")

sit("read_aloud", { label = "Reading aloud", icon = "react_book", gap = 8 })
ln("Once upon a time, a very small dragon had very big opinions.", "role=speaker")
ln("Chapter one. No, we can't skip to the end.", "role=speaker")
ln("And the brave rabbit said... what do you think the rabbit said?", "role=speaker")
ln("Last chapter, then sleep. I mean it. Mostly.", "role=speaker hour>=19")

sit("homework", { label = "Homework help", icon = "react_school", gap = 8 })
ln("Right, show me the problem. Oh. That is a problem.", "role=speaker")
ln("Let's do it together. You do the thinking, I'll do the nodding.", "role=speaker")
ln("Long division? I remember long division. Vaguely. From a distance.", "role=speaker")

---------------------------------------------------------------------------
-- Household incidents
---------------------------------------------------------------------------
sit("messy_plate", { label = "Dirty dishes", icon = "react_mess", gap = 30 })
ln("Looks like the kitchen is expanding into here, one {obj} at a time.", "",
    "A {obj} has been left out, and {speaker} noticed.")
ln("Who left this {obj}? It's starting a small society.", "neat>=6")
ln("Every time I walk past that {obj}, it looks more confident.", "")
ln("I can't relax with a {obj} just sitting there, watching me.", "neat>=8")
ln("That {obj} isn't going to wash itself. I've waited.", "neat>=6")

sit("room_filthy", { label = "A filthy room", icon = "react_mess", gap = 45 })
ln("This room has stopped being a room and started being an event.", "roomScore<=-40",
    "{speaker} has taken in the state of this room, and it is bad.")
ln("I've seen tidier compost heaps.", "roomScore<=-45")
ln("Something in here is alive, and it isn't paying rent.", "mess>=4")
ln("We need to talk about this room. The room needs to talk to someone.", "roomScore<=-55")
ln("Is it always like this? Don't answer that.", "guest roomScore<=-40")
ln("I can feel the mess from here. It's on my skin.", "neat>=8 mess>=3")
ln("I'd tidy up, but I can't tell where the floor starts.", "mess>=5")

sit("bathroom_queue", { label = "Bathroom queue", icon = "react_angry", gap = 10 })
ln("{holder}! Some of us have needs too!", "",
    "{speaker} had to wait while {holder} was in the bathroom.")
ln("How long does one person need in there, {holder}?", "")
ln("I'm not saying hurry up, {holder}. I'm yelling it.", "nice<=4")
ln("Occupied again. This house needs a second bathroom or fewer people.", "")
ln("There's a queue for the {obj} now? What are we, a theme park?", "")
ln("I'll just stand here. Hopping. Thinking about waterfalls.", "playful>=5")

sit("burnt_meal", { label = "A burnt meal", icon = "react_fire", gap = 20, journal = true })
ln("It's not burnt, it's caramelised. All the way through.", "")
ln("{meal}, now available in charcoal.", "")
ln("I was so proud of this {meal}. It had a whole future.", "",
    "{speaker} had high hopes for the {meal}.")
ln("Dinner has entered its crispy era.", "playful>=4")
ln("Who needs the {obj} when you can set things on fire directly?", "")
ln("I followed the recipe. The recipe clearly didn't follow me.", "")

sit("proud_meal", { label = "A proud meal", icon = "react_food", gap = 20 })
ln("Behold: {meal}. Hold the applause until after the first bite.", "")
ln("Chef's kiss. I'm the chef. I kissed it.", "quality>=6")
ln("This might be the best {meal} I've ever made.", "quality>=7")
ln("Dinner is served, and honestly, it's served well.", "quality>=5")
ln("Someone made this {obj} with love. And a lot of butter.", "objDef")
ln("This smells like someone really tried. I respect that.", "")

sit("broken_object", { label = "Something broke", icon = "react_mess", gap = 15 })
ln("The {obj} just gave up. Relatable.", "")
ln("Great. The {obj} is broken, and so is my spirit.", "")
ln("I didn't touch it! Well, I touched it. Gently.", "objDef")
ln("We should call someone about the {obj}. Someone with tools and patience.", "")
ln("Give me five minutes and a spanner. And maybe the manual.", "objDef neat>=5")

sit("puddle", { label = "A puddle", icon = "react_mess", gap = 30 })
ln("Why is the floor wet? Why is it always the floor?", "objDef")
ln("Either something's leaking, or the floor is crying.", "objDef playful>=4")
ln("Someone get a mop before this becomes a pond with opinions.", "objDef")
ln("I just put on clean socks. Clean. Past tense.", "objDef")

sit("pet_mess", { label = "Pet mess", icon = "react_mess", gap = 30 })
ln("{pet}! What did you do? Don't look at me like that.", "")
ln("Someone's pet left a present, and it's not a nice present.", "objDef")
ln("I love {pet}. I do not love what {pet} did here.", "")
ln("This is why we can't have nice floors.", "objDef")

sit("expensive_chair", { label = "An expensive chair", icon = "react_star", gap = 60 })
ln("That {obj} looks like it reads my bank statements.", "objPrice>=900")
ln("Am I allowed to sit on the {obj}, or just admire it from here?", "objPrice>=900 guest")
ln("That {obj} costs more than my car, doesn't it?", "objPrice>=1500")
ln("I'm afraid to sit on the {obj}. It seems to have standards.", "objPrice>=900")

---------------------------------------------------------------------------
-- Money, work and school
---------------------------------------------------------------------------
sit("bill_arrived", { label = "Bills", icon = "react_money", gap = 60 })
ln("A bill for {amount}. Somebody's been using electricity for fun.", "")
ln("Oh good, post. Oh no, it's post.", "")
ln("Bills again. At this rate we'll be paying in buttons.", "money<1000",
    "The household has less than a thousand to its name.")
ln("On the pile with the other bills. The pile is thriving.", "")

sit("bill_overdue", { label = "Overdue bills", icon = "react_money", important = true, gap = 60, journal = true })
ln("This bill is {days} days late. It's started looking at me funny.", "")
ln("We owe {amount}. I'd like to owe it somewhere quieter.", "")
ln("If we ignore it long enough it goes away. Right? Right?", "")
ln("The red letters are back. They never bring good news.", "")

sit("repo_visit", { label = "Repossession", icon = "react_money", important = true, gap = 30, journal = true })
ln("Not the {obj}! We were just starting to understand each other.", "")
ln("You can take the furniture, but you can't take my dignity. Oh. You can.", "")
ln("Please, it's been in the family for nearly a fortnight.", "")
ln("Take the {obj}, then. It never liked us anyway.", "nice<=4")

sit("work_promoted", { label = "Promotion", icon = "react_work", important = true, gap = 5, journal = true })
ln("Promoted! I'm officially a {job}. Somebody frame my name badge.", "")
ln("Promoted! I'd like to thank me, and also coffee.", "")
ln("A raise! {amount} a shift. I'm buying something unnecessary.", "")
ln("They finally noticed me. I'd been standing near the boss for months.", "playful>=4")

sit("work_demoted", { label = "Demotion", icon = "react_work", important = true, gap = 5, journal = true })
ln("Demoted. Apparently enthusiasm isn't a qualification.", "")
ln("Back to {job}. It's fine. I missed the lower desk.", "")
ln("They said it isn't personal. It felt quite personal.", "")
ln("I'm going to go and have a very long bath about this.", "")

sit("work_fired", { label = "Fired", icon = "react_work", important = true, gap = 5, journal = true })
ln("Fired. On the bright side, my mornings are free.", "")
ln("They let me go. I'd been meaning to let them go first.", "nice<=5")
ln("No more {job}. I'll miss the stapler most.", "")
ln("I always wanted to find myself. Now I've got time.", "")

sit("work_late", { label = "Late for work", icon = "react_work", important = true, gap = 20 })
ln("Late again! The carpool left without me, which is fair.", "")
ln("I'm not late. The day just started early.", "")
ln("My boss is going to do the face. The quiet one.", "")
ln("Where are my shoes? Why do they always leave first?", "")

sit("school_good", { label = "Good at school", icon = "react_school", gap = 20 })
ln("I got a {grade}! I'm basically a professor now.", "")
ln("My teacher said I'm 'a pleasure'. I think that's good?", "age=child")
ln("Oh! That actually makes sense now. Thanks!", "role=listener")
ln("Homework: done. Brain: tired. Me: brilliant.", "")
ln("We learned about volcanoes today. I have plans.", "age=child")

sit("school_bad", { label = "Trouble at school", icon = "react_school", gap = 20 })
ln("I got a {grade}. It's a letter. Letters are good, right?", "")
ln("School is just a building full of questions I don't know.", "")
ln("I still don't get it. Can we just say I get it?", "role=listener")
ln("My teacher sent a note home. It's addressed to you. Sorry.", "age=child")
ln("I'm not bad at maths. Maths is bad at me.", "")

sit("career_hired", { label = "A new job", icon = "react_work", important = true, gap = 5, journal = true })
ln("I got the job! {job}. Somebody check they meant me.", "")
ln("{job}, starting straight away, at {amount} a shift. I'm going to buy a sensible bag.", "")
ln("Hired! I nodded at all the right moments and it worked.", "")
ln("A proper job. I'll need a lanyard. I've always wanted a lanyard.", "playful>=4")
ln("Employed. Don't make a fuss. All right, make a small fuss.", "outgoing<=4")

sit("career_leave", { label = "Off to work", icon = "react_work", gap = 60 })
ln("Right, off to be a {job} for a few hours. Hold the fort.", "")
ln("Work time. If anyone needs me, try not to.", "")
ln("Wish me luck. Or coffee. Coffee is a kind of luck.", "hour<=9")
ln("Off I go. Nobody touch my leftovers.", "")
ln("Another shift. I'll be back with stories nobody asked for.", "outgoing>=6")

sit("career_home", { label = "Home from work", icon = "react_work", gap = 60 })
ln("Home! {amount} richer and at least that much more tired.", "")
ln("What a shift. I'm going to lie on the floor for a bit.", "")
ln("I'm back. Don't ask about work. Unless you want the whole saga.", "outgoing>=6")
ln("Work was fine. Everything was fine. I need a sandwich.", "")
ln("Another day as {job}, survived. Barely, but survived.", "")

---------------------------------------------------------------------------
-- Visitors, phone, parties
---------------------------------------------------------------------------
sit("visitor_greet", { label = "Visitor at the door", icon = "react_hello", gap = 8 })
ln("Hello! I brought nothing, but I brought it with enthusiasm.", "guest")
ln("Knock knock! Is this a bad time? Say no.", "guest")
ln("{other}! It's been ages. Well, days. It felt like ages.", "guest rel>=40")
ln("Come in, come in! Mind the... well, mind everything.", "!guest")
ln("Welcome! Ignore the state of things. We're between tidies.", "!guest roomScore<=-30")
ln("Come on in. We tidied. Well, somebody did.", "!guest roomScore>=30")

sit("visitor_wait", { label = "Visitor kept waiting", icon = "react_bored", gap = 15 })
ln("I've been out here so long the doorstep knows my name.", "waitMin>=10")
ln("Hello? Anyone? I can hear you existing in there.", "")
ln("I'll give it five more minutes. Then five more.", "")
ln("Rang the bell. Knocked. Considered a song.", "waitMin>=5")

sit("visitor_refused", { label = "Visitor turned away", icon = "react_no", gap = 15 })
ln("Oh. Right. Another time, then. Or not.", "")
ln("Fine! I didn't want to come in anyway. I did, a bit.", "")
ln("Your loss. I'm excellent company.", "nice<=3")
ln("I'll just walk home slowly and think about this.", "nice>=5")

sit("visitor_ornament", { label = "Guest distracted by an ornament", icon = "react_star", gap = 30 })
ln("Is that {obj} an original? Sorry, were you saying something?", "role=listener",
    "{speaker} ignored {other} to gaze at the {obj}.")
ln("Wow. That {obj}. I could look at it all day. Mm-hm. Go on.", "role=listener")
ln("What did that {obj} cost? Don't tell me. Tell me.", "role=listener")
ln("Sorry, I got lost in that {obj}. What were we talking about?", "role=listener")
ln("That {obj} is worth more than my whole flat, isn't it?", "role=listener objPrice>=2000")
ln("Is that {obj} real? It looks expensive enough to be real.", "!role")
ln("I could stare at that {obj} all day. That's rude, isn't it? Still staring.", "!role")
ln("What a {obj}. {host} has taste. And, clearly, money.", "!role !isHost")

sit("phone_badtime", { label = "Badly timed call", icon = "react_phone", gap = 20 })
ln("Who calls at this hour? Someone about to hear about it.", "hour>=23")
ln("It's the middle of the night! Is someone on fire?", "hour<=5")
ln("Can I call you back? I'm in the middle of... everything.", "")
ln("Hello? No, now's perfect. I love being interrupted.", "nice<=5")
ln("{subject}? Now? Of all the nows?", "")

sit("party_good", { label = "A good party", icon = "react_laugh", gap = 20 })
ln("Best party on the street, and I've been to all of them.", "")
ln("I haven't laughed like this in weeks. My face hurts.", "")
ln("Who knew your friends were this fun? Not you, clearly.", "guest playful>=5")
ln("People will talk about this one for years. The good kind of talk.", "score>=80")

sit("party_bad", { label = "A bad party", icon = "react_bored", gap = 20 })
ln("Is it a party if everyone is standing along the wall?", "")
ln("The snacks have more personality than the guests.", "nice<=5")
ln("I've been to livelier dentist appointments.", "")
ln("Someone should put music on. Or leave. Either would help.", "")

sit("party_leave_bad", { label = "Leaving a bad party", icon = "react_bye", gap = 10 })
ln("Thank you for a memorable evening. I'll work on forgetting it.", "guest",
    "{speaker} slipped out of a party that was not going well.")
ln("I have to go. I left the kettle on. Last week.", "guest")
ln("Well, this was a lot. I'm going home to lie very still.", "")
ln("Is that the time? It's always the time, isn't it. Bye!", "")
ln("It's late and I'm old in spirit. Goodnight!", "hour>=22")

---------------------------------------------------------------------------
-- Shopping and dining
---------------------------------------------------------------------------
sit("shop_browse", { label = "Browsing", icon = "react_think", gap = 10 })
ln("Do I need a {item}? No. Do I want one? Deeply.", "")
ln("Just looking. Looking very hard. With my wallet.", "")
ln("Ooh, this is nice. Ooh, that's the price.", "")
ln("Every shop round here smells like new decisions.", "venue")

sit("shop_checkout", { label = "At the till", icon = "react_money", gap = 10 })
ln("{amount}? For this? It must be very well made.", "")
ln("Put it in a bag. A nice bag. I've earned a nice bag.", "")
ln("Paid. Now I get to justify this to myself for a week.", "")
ln("Receipt? No thanks. I'd rather not have evidence.", "playful>=5")

sit("shop_broke", { label = "Can't afford it", icon = "react_money", important = true, gap = 10 })
ln("Declined? I'll pretend that was a practice run.", "")
ln("I'm {amount} short. Could I pay in charm?", "")
ln("I'll put it back. Gently. Like saying goodbye.", "")
ln("Being skint is hard, but it's great for my willpower.", "")

sit("dine_good", { label = "A good meal out", icon = "react_food", gap = 15 })
ln("This {meal} is so good I want to shake the cook's hand.", "")
ln("Everything here is delicious. Even the water has flavour.", "")
ln("I'm coming back tomorrow. And the day after.", "")
ln("Compliments to the chef. And the chef's mum, probably.", "playful>=4")

sit("dine_bad", { label = "A bad meal out", icon = "react_food", gap = 15 })
ln("We've waited so long I've aged a birthday.", "waitMin>=20")
ln("This {meal} tastes like it was described to the cook over the phone.", "")
ln("I'd send it back, but I don't want to hurt its feelings.", "nice>=5")
ln("Is it meant to be this colour? Don't answer.", "")

---------------------------------------------------------------------------
-- Out and about (community lots)
---------------------------------------------------------------------------
sit("venue_wait", { label = "Waiting to be served", icon = "react_bored", gap = 15 })
ln("Is anyone actually serving today, or is this a museum?", "")
ln("I've read the whole menu twice. I could recite it.", "")
ln("We're next. We've been next for quite a while now.", "")
ln("At this rate I'll be a regular before I get served.", "playful>=4")
ln("Excuse me? Hello? I'm being patient, but loudly.", "nice<=4")

sit("greet_guest", { label = "Meeting up", icon = "react_hello", gap = 6 })
ln("{name}! You made it. I saved us a spot. Mostly by glaring.", "")
ln("There you are, {name}! I was starting to think you'd got lost.", "")
ln("{name}! Perfect timing. I only just got here myself.", "")
ln("Hello, hello! This place is busier than I expected.", "")

sit("host_greet", { label = "Welcome at the door", icon = "react_hello", gap = 6 })
ln("Welcome to {place}! Right this way, mind the step.", "")
ln("Table for you? Follow me, I know a good one.", "")
ln("Lovely to see you. We saved the best table. Well, a table.", "")
ln("Evening! Can I start you off with something?", "hour>=17")

sit("date_good", { label = "A good date", icon = "react_heart", gap = 30, journal = true })
ln("I haven't smiled this much in ages. Thank you, {name}.", "")
ln("Same time next week? Same place? Same everything?", "")
ln("{place} is my favourite place now. Don't tell the others.", "")
ln("You're very easy to talk to, {name}. Suspiciously easy.", "playful>=4")

sit("date_ok", { label = "A pleasant date", icon = "react_heart", gap = 30 })
ln("That was nice. Genuinely nice. I'm saying nice a lot.", "")
ln("Pleasant evening, {name}. We should do it again. Probably.", "")
ln("Good food, good company. Mostly good company.", "nice<=4")

sit("date_bad", { label = "A bad date", icon = "react_awkward", gap = 30, journal = true })
ln("Well. I think I'll get the bus home. Alone. On purpose.", "")
ln("That was an evening, {name}. It certainly happened.", "")
ln("Let's say we both learned something tonight.", "")
ln("I'd stay, but I've just remembered I have a thing. Forever.", "nice>=4")

sit("date_stood_up", { label = "Stood up", icon = "react_sad", gap = 60, journal = true })
ln("{name} said this place, didn't they? I'm sure they said this place.", "")
ln("Stood up at {place}. I'll order for two and eat both.", "")
ln("The waiter keeps looking at the empty chair. So do I.", "")
ln("Fine. I'm on a date with myself. It's going great.", "")

sit("outing_good", { label = "A good outing", icon = "react_star", gap = 30 })
ln("Best day out in ages. We should leave the house more often.", "")
ln("{place} was brilliant. Can we live there?", "")
ln("My feet hurt and I regret nothing.", "")
ln("That was exactly the right amount of fun.", "")

sit("outing_bad", { label = "A bad outing", icon = "react_bored", gap = 30 })
ln("Remind me why we left the house?", "")
ln("Let's never mention {place} again. To anyone.", "")
ln("I could have been at home doing nothing. Comfortably.", "")
ln("Well, that's an afternoon I won't be getting back.", "")

sit("venue_closed", { label = "Closing time", icon = "react_bye", gap = 30 })
ln("{place} is closing. Home time, everyone.", "")
ln("They're stacking chairs around us. I think that's a hint.", "")
ln("Last orders came and went. So should we.", "")

sit("dj", { label = "At the decks", icon = "react_laugh", gap = 10 })
ln("One floor-filler, coming right up!", "")
ln("Good pick. Dance floor, you're welcome.", "")
ln("Requests? I take them. I don't always play them.", "nice<=4")
ln("This next one goes out to everyone standing by the wall.", "")

sit("round", { label = "Buying a round", icon = "react_food", gap = 20 })
ln("This round's on me! Don't get used to it.", "")
ln("Drinks for the table! I'm a generous person, apparently.", "")
ln("Same again for everyone? I've lost count. Same again.", "playful>=5")

sit("wish", { label = "A wish", icon = "react_star", gap = 30 })
ln("I made a wish. No, I'm not telling. That's how wishes break.", "")
ln("Coin in, eyes shut, fingers crossed. The full ritual.", "")
ln("I wished for a quiet week. Let's see how that goes.", "age=adult")
ln("I wished for a pony! Is it here yet?", "age=child")

---------------------------------------------------------------------------
-- Disasters and the uncanny
---------------------------------------------------------------------------
sit("fire_alarm", { label = "Fire alarm", icon = "react_fire", important = true, gap = 2, journal = true })
ln("Everybody out! Dinner has turned into a safety briefing.", "")
ln("Fire! This is not a drill! We don't even do drills!", "")
ln("The {obj} is on fire! Why is the {obj} on fire?!", "")
ln("Get out! Leave everything! Except the people!", "")

sit("fire_panic", { label = "Panic", icon = "react_fire", important = true, gap = 1 })
ln("Water! Someone find water! Or a phone!", "")
ln("I'm panicking! I'm doing it properly and everything!", "")
ln("Don't just stand there! Stand somewhere else!", "")
ln("Is the house going to be okay?!", "age=child")

sit("fire_after", { label = "After the fire", icon = "react_sad", important = true, gap = 10, journal = true })
ln("Well. That's a smell that'll be with us for a while.", "")
ln("Everyone's all right. That's the main thing. Also, the smell.", "")
ln("New rule: nobody cooks while tired.", "age=adult")
ln("We'll rebuild. Starting with a better attitude to smoke.", "")

sit("death_grief", { label = "Grief", icon = "react_sad", important = true, gap = 5, journal = true })
ln("I can't believe {deceased} is gone.", "",
    "{speaker} is grieving for {deceased}.")
ln("{deceased} always knew how to make me laugh. It's too quiet now.", "")
ln("I keep expecting {deceased} to walk in any minute.", "")
ln("Nobody should go like that. Poor {deceased}.", "cause=fire")
ln("Where did {deceased} go? When are they coming back?", "age=child")

sit("ghost_seen", { label = "A ghostly visit", icon = "react_ghost", important = true, gap = 30 })
ln("Did the lights just flicker? Or did {deceased} just say hello?", "")
ln("I saw something in the hallway. It waved!", "")
ln("I don't believe in ghosts. I'm just being polite to one.", "age=adult")
ln("Is it cold in here, or is someone who used to live here visiting?", "")

sit("burglary", { label = "Burglary", icon = "react_angry", important = true, gap = 5, journal = true })
ln("Someone's in the house! Someone who isn't us!", "")
ln("They took the {item}! Who steals a {item}?", "")
ln("Call the police! Then call them again, louder!", "")
ln("I feel so... rummaged.", "")

sit("garden_harvest", { label = "Harvest", icon = "react_star", gap = 30 })
ln("Look at these {plant}! Did I grow these? I grew these!", "")
ln("{count} of them! I'm basically a farmer now.", "count>=5")
ln("Fresh from the garden. Well, fresh from the dirt. Same thing.", "")
ln("Grown with love, water and mild threats.", "playful>=4")

sit("infant_cry", { label = "A crying baby", icon = "react_tired", gap = 20 })
ln("It's the middle of the night and someone has opinions.", "hour<=5")
ln("Shh, shh. I know. I know. Everything is a lot.", "")
ln("What is it this time? Hungry? Bored? Existential?", "")
ln("I'm coming! I'm coming! I'm mostly awake!", "hour>=22")
