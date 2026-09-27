-- SideStreet careers, skills, school and household-economy data.
-- Owner: careers module (see ARCHITECTURE.md §3 and docs/modules/careers.md).
-- Everything tunable lives here; Sim/Skills.lua, Sim/Career.lua, Sim/School.lua and Sim/Economy.lua
-- read these tables and hold no numbers of their own. All job titles and texts are original.
-- Weekdays: 0 = Monday ... 6 = Sunday (ARCHITECTURE.md §4). Hours are 0-23; a shift whose finish
-- is not after its start runs past midnight into the next day.
local _, SS = ...

local D = {}
SS.CareerData = D

---------------------------------------------------------------------------------------------------
-- Skills: six families, levels 0-10, a gradual curve.
-- 1 practice point = 1 level at level 0; level L costs base + perLevel * L points (0->10 = 23.5 points).
D.skills = {
    order = { "cooking", "mechanical", "charisma", "body", "logic", "creativity" },
    labels = {
        cooking = "Cooking", mechanical = "Mechanical", charisma = "Charisma",
        body = "Body", logic = "Logic", creativity = "Creativity",
    },
    -- what practises a skill and what it changes (shown in the skills panel)
    help = {
        cooking = "Practise by cooking and reading cookbooks. Raises meal quality and lowers the chance of burning food.",
        mechanical = "Practise at a workbench or by repairing things. Makes repairs faster and more reliable, and electrical work safer.",
        charisma = "Practise at a mirror or by talking to people. Improves social success and helps in business, civic and stage careers.",
        body = "Practise with exercise equipment, swimming or dancing. Needed for sport, civic and healthcare careers.",
        logic = "Practise with chess, study and homework. Needed for technical, healthcare and business careers.",
        creativity = "Practise by painting or playing an instrument. Raises art quality and value; creative and culinary careers need it.",
    },
    curve = { base = 1.0, perLevel = 0.3 },
    childRate = 0.75,                 -- children learn more slowly
    childCaps = { cooking = 3, mechanical = 3, charisma = 6, body = 6, logic = 7, creativity = 7 },
    moodFactor = 1 / 200,             -- rate x (1 + mood/200), mood clamped to +-60 (0.7 .. 1.3)
    moodClamp = 60,
    -- personality where sensible: outgoing people learn charisma faster, active people body,
    -- playful people creativity, serious (low playful) people logic. Cooking and mechanical: none.
    personality = {
        charisma = { dim = "outgoing", sign = 1 },
        body = { dim = "active", sign = 1 },
        creativity = { dim = "playful", sign = 1 },
        logic = { dim = "playful", sign = -1 },
    },
    personalityMin = 0.85, personalityMax = 1.15,
    journalLevels = { [5] = true, [10] = true },
}

---------------------------------------------------------------------------------------------------
-- Carpool vehicles rise with level. Kinds are drawn by the renderer from SS.Street.vehicles.
D.carpools = { "hatchback", "hatchback", "sedan", "estate", "towncar", "limousine" }

local WEEK = { 0, 1, 2, 3, 4 }

-- level = { title, pay (§ per shift), days, start, finish, skills = { skill = level }, friends,
--           carpool, outfit, desc }
D.tracks = {
    business = {
        name = "Business", order = 1, icon = "career_business",
        desc = "Meetings, memos and the eternal search for a working stapler.",
        work = { hunger = -3.5, energy = -5, hygiene = -1.5, fun = -3, social = 2, comfort = -1 },
        levels = {
            { title = "Photocopy Wrangler", pay = 140, days = WEEK, start = 9, finish = 17, skills = {}, friends = 0, outfit = "office_shirt",
              desc = "Keeps the copier fed and the toner off the carpet." },
            { title = "Spreadsheet Apprentice", pay = 210, days = WEEK, start = 9, finish = 17, skills = { charisma = 1 }, friends = 0, outfit = "office_shirt",
              desc = "Knows eleven ways to colour a cell and uses all of them." },
            { title = "Accounts Juggler", pay = 320, days = WEEK, start = 9, finish = 17, skills = { charisma = 2, logic = 1 }, friends = 1, outfit = "office_suit",
              desc = "Balances the books and occasionally a mug on the books." },
            { title = "Regional Deal Maker", pay = 520, days = WEEK, start = 8, finish = 17, skills = { charisma = 3, logic = 3 }, friends = 2, outfit = "office_suit",
              desc = "Shakes hands in three postcodes before lunch." },
            { title = "Vice President of Synergy", pay = 850, days = { 0, 1, 2, 3 }, start = 9, finish = 18, skills = { charisma = 5, logic = 4, creativity = 2 }, friends = 4, outfit = "power_suit",
              desc = "Nobody knows what synergy is, which is exactly why it needs a vice president." },
            { title = "Chair of the Glass Tower", pay = 1350, days = { 0, 1, 2, 3 }, start = 10, finish = 16, skills = { charisma = 7, logic = 6, creativity = 3 }, friends = 6, outfit = "power_suit",
              desc = "Owns a corner office with a view of other corner offices." },
        },
    },
    culinary = {
        name = "Kitchen Arts", order = 2, icon = "career_culinary",
        desc = "Evenings, weekends and a permanent smell of garlic.",
        work = { hunger = -2.5, energy = -6, hygiene = -4, fun = -1, social = 1, comfort = -4 },
        levels = {
            { title = "Pot Scrub Specialist", pay = 110, days = { 2, 3, 4, 5, 6 }, start = 16, finish = 23, skills = {}, friends = 0, outfit = "kitchen_apron",
              desc = "Returns every pan to its factory shine, eventually." },
            { title = "Salad Station Hand", pay = 170, days = { 2, 3, 4, 5, 6 }, start = 15, finish = 23, skills = { cooking = 1 }, friends = 0, outfit = "kitchen_apron",
              desc = "Can tell a rocket leaf from a regular leaf at twenty paces." },
            { title = "Grill Line Cook", pay = 260, days = { 1, 2, 3, 4, 5 }, start = 14, finish = 22, skills = { cooking = 3 }, friends = 0, outfit = "cook_whites",
              desc = "Flips burgers with the confidence of a circus act." },
            { title = "Second-in-Command Chef", pay = 420, days = { 1, 2, 3, 4, 5 }, start = 13, finish = 21, skills = { cooking = 4, creativity = 2 }, friends = 1, outfit = "cook_whites",
              desc = "Runs the kitchen whenever the head chef is 'tasting' in the storeroom." },
            { title = "Head of the Pass", pay = 680, days = { 2, 3, 4, 5, 6 }, start = 12, finish = 21, skills = { cooking = 6, creativity = 3, charisma = 2 }, friends = 2, outfit = "chef_toque",
              desc = "No plate leaves the kitchen without a nod, a wipe and a sigh." },
            { title = "Tasting-Menu Visionary", pay = 1100, days = { 3, 4, 5, 6 }, start = 17, finish = 23, skills = { cooking = 8, creativity = 5, charisma = 4 }, friends = 3, outfit = "chef_toque",
              desc = "Serves nine courses, each smaller and more expensive than the last." },
        },
    },
    technical = {
        name = "Tech and Gadgets", order = 3, icon = "career_technical",
        desc = "Cables, code and things that beep for reasons of their own.",
        work = { hunger = -3.5, energy = -4, hygiene = -1.5, fun = -2, social = 0.5, comfort = -1 },
        levels = {
            { title = "Cable Untangler", pay = 130, days = WEEK, start = 8, finish = 16, skills = {}, friends = 0, outfit = "tech_polo",
              desc = "Turns the knot behind every desk back into individual wires." },
            { title = "Help Desk Soother", pay = 195, days = WEEK, start = 14, finish = 22, skills = { mechanical = 1 }, friends = 0, outfit = "tech_polo",
              desc = "Asks 'have you tried turning it off and on again' with genuine warmth." },
            { title = "Circuit Tinkerer", pay = 300, days = WEEK, start = 9, finish = 17, skills = { mechanical = 2, logic = 2 }, friends = 0, outfit = "tech_coveralls",
              desc = "Solders things together that were never meant to meet." },
            { title = "Systems Whisperer", pay = 490, days = WEEK, start = 9, finish = 17, skills = { mechanical = 4, logic = 3 }, friends = 1, outfit = "tech_coveralls",
              desc = "Servers calm down when they hear footsteps in the corridor." },
            { title = "Lead Gadget Architect", pay = 790, days = { 0, 1, 2, 3 }, start = 10, finish = 18, skills = { mechanical = 6, logic = 5 }, friends = 1, outfit = "lab_smart",
              desc = "Designs gadgets that solve problems other gadgets created." },
            { title = "Chief Invention Officer", pay = 1280, days = { 0, 1, 2, 3 }, start = 10, finish = 16, skills = { mechanical = 8, logic = 7, creativity = 3 }, friends = 2, outfit = "lab_smart",
              desc = "Has patents on three kinds of spoon and one kind of weather." },
        },
    },
    healthcare = {
        name = "Healthcare", order = 4, icon = "career_healthcare",
        desc = "Rotating shifts, night wards and very clean hands.",
        work = { hunger = -3.5, energy = -7, hygiene = -3, fun = -3, social = 2, comfort = -3 },
        levels = {
            { title = "Ward Errand Runner", pay = 125, days = { 5, 6, 0, 1, 2 }, start = 7, finish = 15, skills = {}, friends = 0, outfit = "ward_tunic",
              desc = "Delivers charts, blankets and the occasional lost grandparent." },
            { title = "Clinic Clipboard Aide", pay = 185, days = { 3, 4, 5, 6, 0 }, start = 15, finish = 23, skills = { logic = 1 }, friends = 0, outfit = "ward_tunic",
              desc = "Owns the clipboard. Fears no queue." },
            { title = "Night Ward Nurse", pay = 290, days = { 0, 1, 2, 5, 6 }, start = 22, finish = 6, skills = { logic = 2, body = 1 }, friends = 1, outfit = "scrubs",
              desc = "Keeps the ward calm from lights-out to the first tea trolley." },
            { title = "Neighbourhood Doctor", pay = 480, days = WEEK, start = 8, finish = 16, skills = { logic = 4, body = 2, charisma = 1 }, friends = 1, outfit = "doctor_coat",
              desc = "Says 'hmm' in eleven reassuring tones." },
            { title = "Specialist in Tricky Knees", pay = 800, days = WEEK, start = 8, finish = 17, skills = { logic = 6, body = 3, charisma = 3 }, friends = 2, outfit = "doctor_coat",
              desc = "The knees of the whole county owe them a favour." },
            { title = "Director of the Whole Hospital", pay = 1320, days = { 0, 1, 2, 3 }, start = 9, finish = 15, skills = { logic = 8, body = 4, charisma = 5 }, friends = 3, outfit = "doctor_coat",
              desc = "Signs the budget, cuts the ribbons and finally gets a parking space." },
        },
    },
    creative = {
        name = "Arts and Media", order = 5, icon = "career_creative",
        desc = "Short days, long ideas and paint in unusual places.",
        work = { hunger = -3.5, energy = -3, hygiene = -2, fun = 2, social = 1, comfort = -1.5 },
        levels = {
            { title = "Gallery Floor Sweeper", pay = 100, days = { 1, 2, 3, 4, 5 }, start = 10, finish = 16, skills = {}, friends = 0, outfit = "paint_smock",
              desc = "Sweeps around the installation that is also, possibly, a pile of dust." },
            { title = "Mural Assistant", pay = 160, days = { 1, 2, 3, 4, 5 }, start = 10, finish = 16, skills = { creativity = 1 }, friends = 0, outfit = "paint_smock",
              desc = "Paints the sky on other people's murals. Very large skies." },
            { title = "Freelance Doodler", pay = 250, days = { 0, 2, 4 }, start = 11, finish = 17, skills = { creativity = 3 }, friends = 1, outfit = "paint_smock",
              desc = "Illustrates cereal boxes, menus and one alarming road safety leaflet." },
            { title = "Studio Art Director", pay = 410, days = { 1, 2, 3, 4, 5 }, start = 11, finish = 18, skills = { creativity = 4, charisma = 2 }, friends = 2, outfit = "studio_black",
              desc = "Points at things and says 'more teal' with total authority." },
            { title = "Exhibited Painter", pay = 700, days = { 2, 3, 4, 5 }, start = 12, finish = 18, skills = { creativity = 6, charisma = 3 }, friends = 3, outfit = "studio_black",
              desc = "Their paintings hang in places with small printed labels." },
            { title = "Living Local Treasure", pay = 1200, days = { 3, 4, 5 }, start = 13, finish = 17, skills = { creativity = 8, charisma = 5, logic = 2 }, friends = 5, outfit = "studio_black",
              desc = "The town names a bench after them while they are still sitting on it." },
        },
    },
    civic = {
        name = "Civic Service", order = 6, icon = "career_civic",
        desc = "Weekends, night patrols and a great many forms.",
        work = { hunger = -3.5, energy = -6, hygiene = -2.5, fun = -2, social = 3, comfort = -3 },
        levels = {
            { title = "Parking Meter Diplomat", pay = 120, days = { 0, 1, 4, 5, 6 }, start = 7, finish = 15, skills = {}, friends = 0, outfit = "hi_vis_vest",
              desc = "Negotiates peace between drivers and the meters they misunderstand." },
            { title = "Crossing Patrol Captain", pay = 180, days = { 0, 1, 4, 5, 6 }, start = 7, finish = 15, skills = { body = 1 }, friends = 1, outfit = "hi_vis_vest",
              desc = "Holds up a lollipop sign and the entire town stops. Power." },
            { title = "Night Beat Officer", pay = 280, days = { 2, 3, 4, 5, 6 }, start = 23, finish = 7, skills = { body = 2, charisma = 1 }, friends = 2, outfit = "patrol_uniform",
              desc = "Walks the quiet streets, mostly returning escaped garden gnomes." },
            { title = "Station Sergeant", pay = 450, days = WEEK, start = 8, finish = 16, skills = { body = 3, charisma = 3, logic = 1 }, friends = 3, outfit = "patrol_uniform",
              desc = "Keeps the station coffee hot and the lost-property cupboard legendary." },
            { title = "Town Hall Undersecretary", pay = 720, days = WEEK, start = 9, finish = 17, skills = { body = 4, charisma = 5, logic = 3 }, friends = 5, outfit = "civic_suit",
              desc = "Drafts the rules about where the rules are kept." },
            { title = "First Citizen of the Borough", pay = 1150, days = { 0, 1, 2, 3 }, start = 9, finish = 15, skills = { body = 5, charisma = 7, logic = 5 }, friends = 8, outfit = "civic_suit",
              desc = "Cuts ribbons, kisses pies and judges the marrow contest without fear or favour." },
        },
    },
    sport = {
        name = "Sport", order = 7, icon = "career_sport",
        desc = "Training days, weekend games and ice packs for everyone.",
        work = { hunger = -5, energy = -9, hygiene = -7, fun = 1, social = 2, comfort = -5 },
        levels = {
            { title = "Water Bottle Carrier", pay = 110, days = { 1, 2, 3, 4, 5 }, start = 9, finish = 15, skills = {}, friends = 0, outfit = "training_kit",
              desc = "Hydration is a team sport, and they are the team." },
            { title = "Practice Squad Hopeful", pay = 180, days = { 1, 2, 3, 4, 5 }, start = 9, finish = 15, skills = { body = 2 }, friends = 0, outfit = "training_kit",
              desc = "Runs every drill twice to be sure someone notices." },
            { title = "First-Class Bench Warmer", pay = 290, days = { 1, 2, 3, 4, 5 }, start = 10, finish = 16, skills = { body = 3 }, friends = 1, outfit = "training_kit",
              desc = "The bench has never been warmer or more ready to go on." },
            { title = "Weekend Match Regular", pay = 500, days = { 3, 4, 5, 6 }, start = 12, finish = 19, skills = { body = 5, charisma = 1 }, friends = 2, outfit = "match_kit",
              desc = "Plays every weekend match and waves at the same six fans." },
            { title = "Captain of the Squad", pay = 830, days = { 3, 4, 5, 6 }, start = 12, finish = 19, skills = { body = 7, charisma = 3 }, friends = 3, outfit = "match_kit",
              desc = "Wears the armband and gives half-time speeches about oranges." },
            { title = "Legend of the League", pay = 1400, days = { 4, 5, 6 }, start = 13, finish = 19, skills = { body = 9, charisma = 5 }, friends = 4, outfit = "match_kit",
              desc = "Has a stand, a chant and a sandwich named after them." },
        },
    },
    entertainment = {
        name = "Stage and Screen", order = 8, icon = "career_entertainment",
        desc = "Late nights, bright lights and a dressing room that is also a cupboard.",
        work = { hunger = -3.5, energy = -6, hygiene = -2, fun = 3, social = 4, comfort = -2 },
        levels = {
            { title = "Ticket Booth Smiler", pay = 100, days = { 3, 4, 5, 6 }, start = 17, finish = 23, skills = {}, friends = 0, outfit = "usher_jacket",
              desc = "Tears tickets with a flourish the audience rarely deserves." },
            { title = "Background Crowd Member", pay = 170, days = { 3, 4, 5, 6 }, start = 17, finish = 23, skills = { charisma = 1 }, friends = 1, outfit = "usher_jacket",
              desc = "Reacts to explosions that will be added later." },
            { title = "Open Mic Regular", pay = 270, days = { 2, 3, 4, 5 }, start = 19, finish = 1, skills = { charisma = 2, creativity = 1 }, friends = 2, outfit = "stage_casual",
              desc = "Tells the same seven jokes to a slightly different room every night." },
            { title = "Late-Night Show Sidekick", pay = 480, days = { 1, 2, 3, 4 }, start = 18, finish = 1, skills = { charisma = 4, creativity = 2, body = 1 }, friends = 4, outfit = "stage_casual",
              desc = "Laughs at the host's jokes at a professionally calibrated volume." },
            { title = "Headlining Crooner", pay = 820, days = { 3, 4, 5 }, start = 19, finish = 1, skills = { charisma = 6, creativity = 4, body = 2 }, friends = 6, outfit = "sequin_suit",
              desc = "Sings ballads so smooth the microphone needs a lie-down." },
            { title = "Household Name", pay = 1380, days = { 4, 5 }, start = 20, finish = 2, skills = { charisma = 8, creativity = 6, body = 3 }, friends = 9, outfit = "sequin_suit",
              desc = "People they have never met call them by their first name in shops." },
        },
    },
}
D.trackOrder = { "business", "culinary", "technical", "healthcare", "creative", "civic", "sport", "entertainment" }
for _, id in ipairs(D.trackOrder) do
    for n, lv in ipairs(D.tracks[id].levels) do
        lv.carpool = lv.carpool or D.carpools[n]
        lv.level = n
    end
end

-- Default needs change per hour away (commute included) when a track does not override a need.
-- bladder: people use the bathroom at work, so it returns at this value if it was lower.
-- hunger: a long day includes a meal break halfway (D.rules.mealBreak), so a full shift does not
-- send anyone home starving.
D.workNeeds = { hunger = -3.5, energy = -5, hygiene = -2, fun = -2, social = 1.5, comfort = -2, bladder = 25 }

---------------------------------------------------------------------------------------------------
-- Career rules (minutes unless noted). Tuning knobs are documented in docs/modules/careers.md.
D.rules = {
    pickupLead = 60,        -- the carpool arrives this long before the shift starts and waits until the start
    commute = 30,           -- travel each way; boarding later than start - commute makes the worker late
    wakeLead = 30,          -- a sleeping worker is woken this long before the carpool arrives
    mealSlack = 10,         -- someone eating when their ride comes finishes first, until this long before the last on-time moment to set off
    mealBreak = { minHours = 6, hunger = 25 }, -- a work day away this long (commute included) has a meal break halfway, no charge (school: D.school.lunch)
    firstShiftDelay = 180,  -- a new hire's first shift starts at least this far in the future
    retryMinutes = 10,      -- after a failed or cancelled walk to the curb, try again after this
    maxSendAttempts = 4,    -- walk-to-curb attempts per pickup (bounded; the carpool leaves anyway)
    mindRecheck = 5,        -- a worker held home to mind an infant or toddler checks again this often (another adult may come home)
    mindGrace = 20,         -- freed from minding this close to departure and not at the curb: still an excused (childcare) miss
    promoteAt = 50,         -- performance needed for promotion (plus skills and friends of the next level)
    minShiftsAtLevel = 2,
    warnAt = -50, demoteAt = -80,
    perf = {
        base = 6,
        mood = { { 40, 6 }, { 10, 3 }, { -20, 0 }, { -50, -5 }, { -101, -10 } },   -- mood at departure -> points
        skill = 6, skillOffset = 2,     -- + skill * readiness(0..1) - offset
        friends = 2,                    -- when the next level's friend count is met
        latePerMin = 1 / 3, lateMax = 10,
        miss = -20, childcare = -5,
        promotedTo = 15, demotedTo = -10,
    },
    missWindowDays = 14,    -- misses inside this window count toward demotion/dismissal
    warningClearShifts = 5, -- consecutive attended shifts that clear one warning
    vacationEvery = 5, vacationCap = 5,
    friendLife = 50,        -- a friend: long-term relationship at least this (fallback when social has no FriendCount)
    chance = { p = 0.12, cooldownDays = 4, autoResolveHours = 6, recent = 3 },
    readyMessageDays = 2,   -- "ready for promotion but..." at most this often
}

D.jobSearch = { newspaper = 3, computer = 5, phone = 3, maxOfferLevel = 3 }
-- Chance of a job offer above level 1 (only up to maxOfferLevel; requirements still apply).
D.jobSearch.higherChance = 0.35

-- Coworkers named in chance events (one per job, picked when hired). A coworker friendship at or
-- above rules.friendLife counts as one friend toward promotions.
D.coworkerNames = {
    "Petra Quillfeather", "Desmond Farrow", "Ines Marchbank", "Otto Brambleby", "Wren Castellane", "Hugo Pennywhistle",
    "Marisol Tuck", "Felix Ashgrove", "Opal Rennick", "Barnaby Sloe", "Clementine Voss", "Rafferty Doyle",
    "Hattie Larkspur", "Jasper Quint", "Noor Halloway", "Silas Underhay",
}

---------------------------------------------------------------------------------------------------
-- Career chance events: 2 per track, each with two choices and real consequences.
-- choice = { label, tip, default = bool (picked if the player never answers), check = { skill, base, per },
--            success = outcome, failure = outcome }  or  { label, outcome = outcome }
-- outcome = { text, perf, money, skill = { name, levels }, rel = { who = "household"|"coworker", daily, life },
--             needs = { need = delta }, vacation }
D.chance = {
    { id = "biz_projector", track = "business", minLevel = 1, title = "The Projector Incident",
      text = "Ten minutes before the big pitch the projector will only show the colour mauve. The client is already seated and judging the pastries.",
      choices = {
          { label = "Present it from memory", tip = "A charisma test. Success impresses the client.",
            check = { skill = "charisma", base = 0.30, per = 0.07 },
            success = { text = "The client calls the pitch 'refreshingly screen-free' and signs on the spot.", perf = 18, money = 250 },
            failure = { text = "Halfway through, the quarterly figures turn into a locker combination.", perf = -12 } },
          { label = "Let a colleague take it", default = true, tip = "Safe. Your colleague will remember the favour.",
            outcome = { text = "Your colleague shines. They owe you one, and they know it.", perf = -3, rel = { who = "coworker", daily = 12, life = 8 } } },
      } },
    { id = "biz_weekend", track = "business", minLevel = 2, title = "The Weekend Spreadsheet",
      text = "Your manager needs a forty-tab spreadsheet by Monday. It is Friday, and it is 4:55 PM.",
      choices = {
          { label = "Take it home", tip = "Costs sleep and a family evening. Earns respect and logic.",
            outcome = { text = "You finish at 2 AM. Nobody opens tab thirty-one, but you know it is perfect.", perf = 15, skill = { name = "logic", levels = 0.6 }, needs = { energy = -30 }, rel = { who = "household", daily = -6, life = -2 } } },
          { label = "Decline politely", default = true, tip = "A charisma test. Failing annoys your manager.",
            check = { skill = "charisma", base = 0.35, per = 0.06 },
            success = { text = "Your manager respects the boundary and finds a spreadsheet enthusiast instead.", perf = 0, rel = { who = "household", daily = 5, life = 1 } },
            failure = { text = "Your manager nods slowly, the way people nod at a parking ticket.", perf = -10 } },
      } },
    { id = "cul_critic", track = "culinary", minLevel = 1, title = "A Critic in Booth Six",
      text = "A food critic is eating alone in booth six, taking notes on the bread. The head cook has gone to 'check on the parsley'.",
      choices = {
          { label = "Cook the critic's order yourself", tip = "A cooking test.",
            check = { skill = "cooking", base = 0.25, per = 0.08 },
            success = { text = "The review calls the soup 'confident'. Your name is spelled almost correctly.", perf = 20, money = 200 },
            failure = { text = "The review describes the risotto as 'structurally ambitious'.", perf = -15 } },
          { label = "Send out a free dessert", default = true, tip = "The dessert comes out of your pay.",
            outcome = { text = "The critic mentions the dessert, not the meal. Nobody is sure if that is good.", perf = 4, money = -40 } },
      } },
    { id = "cul_party", track = "culinary", minLevel = 1, title = "The Party of Forty",
      text = "A party of forty arrives without a booking, all wearing the same birthday hat.",
      choices = {
          { label = "Stay late and help plate", tip = "Overtime pay, sore feet.",
            outcome = { text = "Forty plates, forty hats, one very long evening. The overtime is welcome.", perf = 12, money = 120, needs = { energy = -25, hygiene = -20 } } },
          { label = "Leave on time", default = true, tip = "Home for dinner; the kitchen notices.",
            outcome = { text = "You slip out during the second chorus of the birthday song.", perf = -5, needs = { fun = 10 }, rel = { who = "household", daily = 5, life = 1 } } },
      } },
    { id = "tech_server", track = "technical", minLevel = 1, title = "The Humming Server",
      text = "The office server has started humming a tune nobody can name. Nobody can log in, and everyone is becoming poetic about it.",
      choices = {
          { label = "Open the case and fix it", tip = "A mechanical test. Failure costs a repair bill.",
            check = { skill = "mechanical", base = 0.30, per = 0.07 },
            success = { text = "A moth had built a small home against the fan. You relocate it with dignity.", perf = 18, skill = { name = "mechanical", levels = 0.5 } },
            failure = { text = "You fix the hum. You also fix the lights, permanently off. The repair comes out of your pay.", perf = -12, money = -100 } },
          { label = "Write a very detailed ticket", default = true, tip = "Safe and educational.",
            outcome = { text = "Your ticket is praised as 'a novel'. It is also still open.", perf = 2, skill = { name = "logic", levels = 0.3 } } },
      } },
    { id = "tech_napkin", track = "technical", minLevel = 2, title = "The Napkin Blueprint",
      text = "You sketch a gadget on a napkin at lunch. A colleague says it could actually work.",
      choices = {
          { label = "Pitch it to the boss", tip = "A logic test. Success pays a bonus.",
            check = { skill = "logic", base = 0.25, per = 0.06 },
            success = { text = "The boss funds a prototype, and your name goes on a sticky note of honour.", perf = 15, money = 400 },
            failure = { text = "The boss asks what it does. You would also like to know.", perf = -6 } },
          { label = "Build it with the colleague", default = true, tip = "Friendship and creativity.",
            outcome = { text = "You build it together over lunch. It toasts one side of bread beautifully.", rel = { who = "coworker", daily = 15, life = 10 }, skill = { name = "creativity", levels = 0.4 } } },
      } },
    { id = "health_double", track = "healthcare", minLevel = 1, title = "The Double Shift",
      text = "The next shift's nurse is snowed in two streets away. The ward needs someone for another eight hours.",
      choices = {
          { label = "Stay for the double", tip = "Extra pay and respect; you come home exhausted.",
            outcome = { text = "Sixteen hours, three cups of cold tea and a thank-you card from bed four.", perf = 15, money = 180, needs = { energy = -40, comfort = -20 } } },
          { label = "Go home and rest", default = true, tip = "Keeps you fresh; the ward is short.",
            outcome = { text = "You go home. The ward copes, and mentions it.", perf = -4, needs = { energy = 10 } } },
      } },
    { id = "health_rash", track = "healthcare", minLevel = 2, title = "The Map-Shaped Rash",
      text = "A patient has a rash shaped exactly like the county map. The senior doctor is stumped.",
      choices = {
          { label = "Offer your theory", tip = "A logic test.",
            check = { skill = "logic", base = 0.30, per = 0.07 },
            success = { text = "It was the new wallpaper. The patient hugs you, which is technically against procedure.", perf = 20, skill = { name = "logic", levels = 0.4 } },
            failure = { text = "Your theory involves pollen from the moon. The ward will remember it for years.", perf = -10 } },
          { label = "Look it up after your shift", default = true, tip = "Costs your evening, teaches logic.",
            outcome = { text = "You read about rashes until midnight and dream in diagrams.", perf = 2, skill = { name = "logic", levels = 0.6 }, needs = { energy = -10, fun = -10 } } },
      } },
    { id = "art_commission", track = "creative", minLevel = 1, title = "A Portrait of a Cat",
      text = "A wealthy client wants a portrait of their cat 'in the style of a thunderstorm'.",
      choices = {
          { label = "Paint it with feeling", tip = "A creativity test. A good result pays well.",
            check = { skill = "creativity", base = 0.30, per = 0.07 },
            success = { text = "The cat looks majestic and slightly damp. The client pays extra.", perf = 15, money = 300 },
            failure = { text = "The client says the cat looks 'worried about taxes' and pays half.", perf = -8, money = 60 } },
          { label = "Recommend a colleague", default = true, tip = "Good for a friendship.",
            outcome = { text = "Your colleague paints the cat as a storm cloud. Everyone is delighted.", perf = 2, rel = { who = "coworker", daily = 12, life = 6 } } },
      } },
    { id = "art_opening", track = "creative", minLevel = 2, title = "Opening Night",
      text = "Your work is in a group show tonight. The wine is warm and the critics are colder.",
      choices = {
          { label = "Work the room", tip = "A charisma test. A sale is possible.",
            check = { skill = "charisma", base = 0.30, per = 0.07 },
            success = { text = "You sell a piece to someone who calls it 'brave'.", perf = 10, money = 250, needs = { social = 30 } },
            failure = { text = "You explain your painting for twenty minutes to a waiter.", perf = -5, needs = { social = 10, fun = -10 } } },
          { label = "Stand by your painting looking mysterious", default = true, tip = "Quiet, creative, a bit lonely.",
            outcome = { text = "Three people ask if you are part of the installation.", perf = 4, skill = { name = "creativity", levels = 0.3 }, needs = { social = -10 } } },
      } },
    { id = "civic_parade", track = "civic", minLevel = 1, title = "The Parade Route",
      text = "The Founders' Day parade route runs straight through a road that is currently a hole.",
      choices = {
          { label = "Redirect the parade yourself", tip = "A charisma test.",
            check = { skill = "charisma", base = 0.35, per = 0.06 },
            success = { text = "The parade takes a scenic detour. Everybody claims it was planned.", perf = 16, rel = { who = "coworker", daily = 8, life = 4 } },
            failure = { text = "The marching band ends up in a car park. They play anyway.", perf = -10 } },
          { label = "Fill out the incident forms", default = true, tip = "Dull but safe.",
            outcome = { text = "Form 12-B, form 12-C and, alarmingly, form 12-B again.", perf = 5, skill = { name = "logic", levels = 0.3 }, needs = { fun = -15 } } },
      } },
    { id = "civic_dog", track = "civic", minLevel = 1, title = "The Loyal Stray",
      text = "A small dog has followed you around your round all afternoon. It has a collar but no manners.",
      choices = {
          { label = "Walk it home after your shift", tip = "A body test; the owner may be grateful.",
            check = { skill = "body", base = 0.40, per = 0.05 },
            success = { text = "The owner is so grateful they bake you a cake the size of a hubcap.", perf = 8, rel = { who = "coworker", daily = 15, life = 10 }, needs = { energy = -15, hunger = 20 } },
            failure = { text = "The dog walks you home instead. You get lost twice.", perf = 2, needs = { energy = -25 } } },
          { label = "Take it to the shelter", default = true, tip = "Quick and responsible.",
            outcome = { text = "The shelter staff know the dog by name. It escapes a lot.", perf = 4, needs = { fun = -5 } } },
      } },
    { id = "sport_hamstring", track = "sport", minLevel = 1, title = "The Twanging Hamstring",
      text = "Your hamstring makes a noise like a guitar string just before the big match.",
      choices = {
          { label = "Play through it", tip = "A body test. Big win or a long evening on ice.",
            check = { skill = "body", base = 0.30, per = 0.07 },
            success = { text = "You score the deciding point and limp off heroically.", perf = 20, money = 300 },
            failure = { text = "You spend the second half on ice, literally.", perf = -10, needs = { comfort = -30, energy = -20 } } },
          { label = "Sit it out and rest", default = true, tip = "You lose a little conditioning.",
            outcome = { text = "You rest the leg and watch from the bench with a blanket.", perf = -4, skill = { name = "body", levels = -0.2 }, needs = { comfort = 20 } } },
      } },
    { id = "sport_fans", track = "sport", minLevel = 2, title = "The Junior Fan Club",
      text = "A children's fan club has come to training with a banner that spells your name almost right.",
      choices = {
          { label = "Spend the afternoon signing and coaching", tip = "Tiring, charming, good for charisma.",
            outcome = { text = "You sign forty-two shirts and one confused parent.", perf = 8, skill = { name = "charisma", levels = 0.4 }, needs = { energy = -15, social = 25 } } },
          { label = "Wave and keep training", default = true, tip = "Focus on fitness.",
            outcome = { text = "You wave. They wave back, harder.", perf = 4, skill = { name = "body", levels = 0.4 }, needs = { social = -5 } } },
      } },
    { id = "ent_heckler", track = "entertainment", minLevel = 1, title = "The Heckler",
      text = "A man in the third row keeps shouting the punchlines before you finish them. He is mostly right.",
      choices = {
          { label = "Improvise a comeback", tip = "A charisma test.",
            check = { skill = "charisma", base = 0.30, per = 0.07 },
            success = { text = "The crowd roars and the heckler asks for your autograph.", perf = 18, money = 150 },
            failure = { text = "Your comeback is a sound, not a word.", perf = -12, needs = { fun = -15 } } },
          { label = "Invite him on stage", default = true, tip = "A creativity test. Could be the best show all month.",
            check = { skill = "creativity", base = 0.35, per = 0.05 },
            success = { text = "You do a double act. It is the best show of the month.", perf = 14, rel = { who = "coworker", daily = 10, life = 5 } },
            failure = { text = "He takes the microphone and does not give it back.", perf = -8 } },
      } },
    { id = "ent_audition", track = "entertainment", minLevel = 2, title = "A Last-Minute Audition",
      text = "A casting agent needs someone who can sing, dance and fall off a stool convincingly. Today.",
      choices = {
          { label = "Go straight to the audition", tip = "A creativity test for a paid part.",
            check = { skill = "creativity", base = 0.30, per = 0.07 },
            success = { text = "You get a small part and a very large stool.", perf = 12, money = 350 },
            failure = { text = "You fall off the stool unconvincingly.", perf = -4, needs = { fun = -10 } } },
          { label = "Stay home and rehearse", default = true, tip = "Creativity and a family evening.",
            outcome = { text = "You rehearse in the kitchen for an audience of one very patient relative.", skill = { name = "creativity", levels = 0.5 }, rel = { who = "household", daily = 5, life = 2 } } },
      } },
}

---------------------------------------------------------------------------------------------------
-- School (children). Weekdays only. Minutes after midnight.
D.school = {
    days = { 0, 1, 2, 3, 4 },
    busAt = 7 * 60, busWait = 30,           -- the bus arrives at 7:00 and leaves at 7:30
    start = 8 * 60, finish = 15 * 60,       -- school day
    returnAt = 15 * 60 + 30,                -- the bus drops children at the curb
    wakeLead = 45,
    gradeStart = 70,
    letters = { { 85, "A" }, { 70, "B" }, { 55, "C" }, { 40, "D" }, { -1, "F" } },
    homework = { minutes = 60, done = 5, missing = -6, logicBonusAt = 3, logicBonus = 1, planBonus = 2,
                 skill = { logic = 0.25, creativity = 0.08 }, fun = -6 },
    mood = { { 40, 3 }, { 0, 1 }, { -30, -2 }, { -101, -5 } },
    absence = -10,
    needs = { hunger = -3, energy = -4, hygiene = -2, fun = -2, social = 3, comfort = -2, bladder = 30 },
    lunch = { minHours = 6, hunger = 15 }, -- the school lunch, halfway through the day: children still come home ready for a snack
    report = { weekday = 4, hour = 16,
        effects = {
            A = { money = 50, fun = 20, social = 10, rel = 5, text = "An A! The school sends a §50 book token and a gold sticker." },
            B = { money = 20, fun = 10, rel = 2, text = "A solid B. A §20 token for good work." },
            C = { fun = 0, text = "A C: 'capable of more', as report cards have said since report cards began." },
            D = { fun = -10, concern = 1, text = "A D. The teacher has written 'see me' twice, underlined." },
            F = { fun = -20, concern = 2, text = "An F. The report card arrives folded very small." },
        } },
    concern = { absence = 2, alone = 1, homeworkStreak = 3, streakConcern = 1,
                noteAt = 2, meetingAt = 4, referralAt = 7, goodDaysDecay = 5 },
    alone = { dayMinutes = 240, nightMinutes = 120, nightFrom = 22, nightTo = 6 },
    counselor = { hour = 16, minute = 30, waitMinutes = 120, meetingMinutes = 30, planDays = 5, relief = 2, missed = 2,
        maxTries = 3 }, -- visits moved because no counselor could come, before the school writes instead
}

---------------------------------------------------------------------------------------------------
-- Household economy: starter budget and price scale (ARCHITECTURE.md §9.7). Prices in §.
D.economy = {
    startMoney = 20000,
    land = { perCell = 40, min = 4000, max = 14000 },      -- vacant residential land by size
    furnishedStarter = { min = 15000, max = 20000 },       -- a furnished starter house totals this
    foodBuffer = 500,                                       -- keep at least this after buying a house: with §0 left
                                                            -- nobody can buy groceries before the first payday
    wages = { min = 100, max = 1400 },                      -- per shift, career levels 1-6
    services = { hourlyMin = 10, hourlyMax = 50 },          -- visitors module prices services in this band
    foodPerPersonDay = 18,                                  -- planning figure for the viability checks
    objectBands = {                                         -- catalogue prices follow these bands
        chair_cheap = { 60, 120 }, armchair = { 250, 800 }, sofa = { 300, 1500 }, bed = { 300, 3000 },
        fridge = { 450, 2500 }, stove = { 400, 1800 }, toilet = { 300, 1200 }, tv = { 500, 3500 }, painting = { 80, 5000 },
    },
    bills = {
        everyDays = 3, deliverHour = 10, carrierDeadlineHour = 12,
        dueDays = 3, finalNoticeDays = 1, collectDays = 2,  -- warning at due, final notice a day later, collector 2 days after due
        levyRate = 0.006,                                   -- property levy: share of lot value per bill
        base = 25,                                          -- flat service charge per bill
        utilities = { powered = 3, plumbing = 3, light = 1 }, -- per object per bill
        min = 40, max = 2500,
        keepSettled = 12,                                   -- paid/collected bills kept for the ledger screen
        garnish = 0.5,                                      -- share of each paycheck withheld for arrears
    },
    depreciation = { initial = 0.85, perDay = 0.01, floor = 0.5, broken = 0.5, burnt = 0.1, dirty = 0.9, sameDayMinutes = 1440 },
    -- building value (the same numbers as hood's own appraisal): a wall edge plus both side finishes (a
    -- finish without a price counts wallFinish), openings and fences by kind, each non-lawn floor tile
    -- plus its finish (floorFinish when unpriced), each extra story, each roofed cell, each pool cell
    structure = { wall = 60, wallFinish = 4, door = 260, window = 180, arch = 120, fence = 22, gate = 90, railing = 30, halfwall = 45,
                  floorBase = 5, floorFinish = 8, storyBonus = 400, roofPerTile = 14, poolPerTile = 240 },
    collector = { maxObjects = 3, maxVisits = 3, retryDays = 1, takeMinutes = 8, arriveDelay = 30, requestTimeout = 120, walkAttempts = 3 },
    ledger = {
        order = { "wages", "bills", "food", "purchases", "sales", "services", "gifts", "fines", "debug", "other" },
        labels = { wages = "Wages", bills = "Bills", food = "Food", purchases = "Purchases", sales = "Sales",
                   services = "Services", gifts = "Gifts", fines = "Fines", debug = "Debug/sandbox", other = "Other" },
        -- raw categories other modules pass to SS.Money -> ledger category
        map = { wages = "wages", wage = "wages", salary = "wages", bills = "bills", bill = "bills",
                food = "food", groceries = "food", dining = "food", purchase = "purchases", purchases = "purchases",
                build = "purchases", buy = "purchases", refund = "purchases", shopping = "purchases",
                sale = "sales", sales = "sales", sell = "sales", service = "services", services = "services",
                gift = "gifts", gifts = "gifts", fine = "fines", fines = "fines", debug = "debug", sandbox = "debug",
                expense = "other", other = "other" },
        -- text patterns that refine a generic ("expense"/"other") entry; first match wins
        textMap = { { "^Groceries", "food" }, { "^Meal", "food" }, { "^Snack", "food" }, { "^Takeout", "food" },
                    { "^Bought", "purchases" }, { "^Sold", "sales" }, { "^Paid:", "bills" }, { "^Fine", "fines" },
                    { "^Service", "services" }, { "^Gift", "gifts" } },
        keepDays = 28,
    },
    sandbox = { presets = { 1000, 10000, 50000 } },
    -- Money pressure: an optional difficulty per save (world.settings.moneyPressure). It scales the
    -- household bill and the wage of each shift; "standard" is the default the A17 viability test uses.
    pressure = {
        order = { "relaxed", "standard", "tight" }, default = "standard",
        levels = {
            relaxed = { label = "Relaxed", bills = 0.6, wages = 1.15,
                desc = "Household bills are 40% lower and wages 15% higher. A gentler game." },
            standard = { label = "Standard", bills = 1, wages = 1,
                desc = "The normal economy: a starter household lives on ordinary jobs and slowly saves." },
            tight = { label = "Tight", bills = 1.3, wages = 0.9,
                desc = "Household bills are 30% higher and wages 10% lower. Every purchase needs thought." },
        },
    },
}
SS.EconomyData = D.economy
