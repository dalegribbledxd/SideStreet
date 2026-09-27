-- SideStreet premade households and townies for Linden Hollow (brief §9): four households with
-- their own houses, tensions, relationship web, money, interests, starter jobs, initial needs and
-- a solvable starter problem, plus three households waiting in the household bin and a pool of
-- townies for walk-bys and visits. All ids are persistent.
-- Owner: hood module. Sim/Hood.lua turns this data into saved residents/households (NewNeighborhood).
-- Roz Kettering (r1, hh_kettering, 4 Juniper Lane) is the existing starter from Data/Fixtures.lua and
-- is kept exactly as it was; this file only adds her interests and her household's problem.
local _, SS = ...
local HD = SS.HoodData
local PM = {}
SS.Premades = PM

local function find(list, id)
    for _, e in ipairs(list) do if e.id == id then return e.c end end
    return list[1].c
end
local function cc(n) local c = HD.ClothColors[n] or HD.ClothColors[1]; return { c[1], c[2], c[3] } end
local function copy3(c) return { c[1], c[2], c[3] } end

-- look{ skin, hair, style, body, face, everyday = { style, top, bottom, shoes }, sleep, swim, work, formal }
-- (colours are indices into HD.ClothColors)
local function look(t)
    local L = { skinId = t.skin, skin = copy3(find(HD.SkinTones, t.skin)), hairId = t.hair, hair = copy3(find(HD.HairColors, t.hair)),
        hairStyle = t.style, body = t.body or "average", face = t.face or 1, outfits = {} }
    for _, k in ipairs(HD.OutfitKinds) do
        local o = t[k] or t.everyday
        L.outfits[k] = { style = o[1], top = cc(o[2]), bottom = cc(o[3]), shoes = cc(o[4]) }
    end
    local e = L.outfits.everyday
    L.top, L.bottom, L.shoes = copy3(e.top), copy3(e.bottom), copy3(e.shoes)
    return L
end
PM.Look = look

---------------------------------------------------------------------------
-- Starter problems. Goals are checked every sim hour while the household is played
-- (Sim/Hood.lua): { "seats", n } | { "skill", rid, skill, level } | { "rel", a, b, daily } |
-- { "money", amount } | { "clean", maxDirty } | { "job", rid }.
---------------------------------------------------------------------------
PM.problems = {
    bungalow = {
        title = "Room for company",
        text = "The bungalow seats exactly one guest, provided the fern agrees to stand. Roz has never had anyone round, and the neighbours have started to notice.",
        hint = "Buy seating until the house has four seats. A sofa counts for every cushion.",
        goal = { { "seats", 4 } },
    },
    school_run = {
        title = "The school-run shuffle",
        text = "Dana's hospital shift starts at the same minute as the school bus, and Theo's cooking repertoire is one burnt crumpet. Mornings are a relay race nobody trained for.",
        hint = "Have Theo study cooking (a bookshelf or practice at the stove) until he reaches cooking level 2, so breakfast no longer depends on Dana.",
        goal = { { "skill", "p_theo", "cooking", 2 } },
    },
    kitchen = {
        title = "Enthusiasm is not a recipe",
        text = "Mo cooks every evening with total confidence and no skill; Priya cleans up behind him with total skill and no patience; Gus eats whatever survives. One counter, three opinions.",
        hint = "Get Mo to cooking level 3, and keep Priya and Gus on speaking terms (Priya's daily feeling for Gus at 10 or better).",
        goal = { { "skill", "p_mo", "cooking", 3 }, { "rel", "p_priya", "p_gus", 10 } },
    },
    free_time = {
        title = "Two calendars, no evenings",
        text = "Vivian and Laurence own a pool, a piano and forty-one paintings, and have not had dinner together since the pool was filled.",
        hint = "Get their daily feelings for each other to 50 both ways: eat together, talk, and let the work phone ring.",
        goal = { { "rel", "p_vivian", "p_laurence", 50 }, { "rel", "p_laurence", "p_vivian", 50 } },
    },
}

---------------------------------------------------------------------------
-- Households. lot = nil puts the household in the household bin. money = nil uses the
-- household-core starting money (Roz, as in the original fixture).
---------------------------------------------------------------------------
PM.households = {
    { id = "hh_kettering", name = "Kettering", lot = "lot_juniper_4", problem = "bungalow", starter = true,
      bio = "Roz on her own, one chair, several ferns and a firm belief that snacks are a form of planning." },
    { id = "hh_halloran", name = "Halloran", lot = "lot_juniper_3", money = 9500, problem = "school_run",
      bio = "A nurse, an illustrator, two children and a staircase that creaks on step four. Somebody is always late for something.",
      members = { "p_dana", "p_theo", "p_pip", "p_juno" } },
    { id = "hh_flatshare", name = "Juniper Flatshare", lot = "lot_juniper_5", money = 4200, problem = "kitchen",
      bio = "Three roommates, one bathroom, one counter and a sofa on the front lawn that nobody admits to owning.",
      members = { "p_priya", "p_gus", "p_mo" } },
    { id = "hh_ashcombe", name = "Ashcombe", lot = "lot_alder_2", money = 38000, problem = "free_time",
      bio = "Well-off, well-dressed and hardly ever home. The house is lovely; the calendar is not.",
      members = { "p_vivian", "p_laurence" } },
    -- household bin (no lot yet)
    { id = "hh_marlowe", name = "Marlowe", money = 20000,
      bio = "Retired, restless and looking for a smaller house with a bigger garden. Laurence Ashcombe's parents.",
      members = { "p_ottilie", "p_bram" } },
    { id = "hh_sato", name = "Sato", money = 20000,
      bio = "A personal trainer new to town with a van full of kettlebells and nowhere to park it.",
      members = { "p_kenji" } },
    { id = "hh_finch", name = "Finch", money = 20000,
      bio = "Leona and her son Toby, fresh from the city. Leona is Dana Halloran's younger sister and has opinions about that.",
      members = { "p_leona", "p_toby" } },
}

---------------------------------------------------------------------------
-- People. needs are initial values (-100..100). starterJob is taken the first time the household
-- is played (SS.Career.Hire, guarded). skills 0..10.
---------------------------------------------------------------------------
local function needs(h, e, b, hy, f, s, c, r)
    return { hunger = h, energy = e, bladder = b, hygiene = hy, fun = f, social = s, comfort = c, room = r }
end

PM.people = {
    -- Halloran (3 Juniper Lane)
    p_dana = { name = "Dana Halloran", age = "adult", pronoun = "she",
        bio = "Night-shift veteran, day-shift parent. Can find a plaster in the dark and a missing shoe in under a minute.",
        look = look({ skin = "sand", hair = "chestnut", style = "ponytail", body = "slim", face = 2,
            everyday = { "sweater_slacks", 2, 11, 3 }, sleep = { "pajamas", 12, 12, 8 }, swim = { "one_piece", 1, 1, 8 },
            work = { "scrubs", 1, 1, 8 }, formal = { "cocktail", 7, 7, 9 } }),
        personality = { neat = 8, outgoing = 4, active = 6, playful = 1, nice = 6 },
        interests = { science = 7, cooking = 3, townnews = 5, weather = 4 },
        skills = { cooking = 3, mechanical = 1, charisma = 2, body = 3, logic = 4, creativity = 1 },
        needs = needs(30, -10, 20, 25, 5, 20, 10, 20), starterJob = { track = "healthcare", level = 2 } },
    p_theo = { name = "Theo Halloran", age = "adult", pronoun = "he",
        bio = "Freelance illustrator of other people's children's books. Works from the studio upstairs, mostly on doodles.",
        look = look({ skin = "sand", hair = "darkbrown", style = "curly", body = "broad", face = 6,
            everyday = { "hoodie_shorts", 6, 2, 3 }, sleep = { "tee_shorts", 11, 2, 8 }, swim = { "trunks", 4, 4, 8 },
            work = { "overalls", 6, 2, 3 }, formal = { "vest", 9, 9, 9 } }),
        personality = { neat = 1, outgoing = 6, active = 3, playful = 9, nice = 6 },
        interests = { art = 9, films = 6, books = 5, cooking = 1 },
        skills = { cooking = 0, mechanical = 0, charisma = 2, body = 1, logic = 1, creativity = 6 },
        needs = needs(20, 40, 30, 5, 55, 35, 30, 20) },
    p_pip = { name = "Pip Halloran", age = "child", pronoun = "he",
        bio = "Eight, fast, loud and certain that the stairs are for jumping down.",
        look = look({ skin = "sand", hair = "chestnut", style = "short", body = "average", face = 1,
            everyday = { "tee_jeans", 4, 2, 3 }, sleep = { "pajamas", 12, 2, 8 }, swim = { "trunks", 12, 12, 8 },
            work = { "tee_jeans", 4, 2, 3 }, formal = { "vest", 2, 2, 9 } }),
        personality = { neat = 2, outgoing = 7, active = 9, playful = 6, nice = 1 },
        interests = { sports = 9, pets = 6, music = 3 },
        skills = { body = 2 },
        needs = needs(15, 50, 25, -10, -15, 30, 40, 20) },
    p_juno = { name = "Juno Halloran", age = "child", pronoun = "she",
        bio = "Ten, quiet and three library books ahead of everyone. Keeps a list of Pip's crimes.",
        look = look({ skin = "sand", hair = "auburn", style = "braids", body = "slim", face = 5,
            everyday = { "cardigan_dress", 7, 7, 1 }, sleep = { "nightgown", 10, 10, 8 }, swim = { "one_piece", 7, 7, 8 },
            work = { "cardigan_dress", 7, 7, 1 }, formal = { "gown", 10, 10, 9 } }),
        personality = { neat = 7, outgoing = 1, active = 2, playful = 5, nice = 10 },
        interests = { books = 10, science = 6, art = 4 },
        skills = { logic = 2, creativity = 1 },
        needs = needs(25, 45, 30, 40, 20, -5, 35, 20) },
    -- Juniper Flatshare (5 Juniper Lane)
    p_priya = { name = "Priya Varma", age = "adult", pronoun = "she",
        bio = "Systems analyst, label-maker owner, keeper of the washing-up rota nobody else reads.",
        look = look({ skin = "amber", hair = "black", style = "bun", body = "slim", face = 5,
            everyday = { "blouse_skirt", 8, 2, 9 }, sleep = { "pajamas", 1, 1, 8 }, swim = { "one_piece", 2, 2, 8 },
            work = { "blazer", 2, 2, 9 }, formal = { "gown", 1, 1, 9 } }),
        personality = { neat = 10, outgoing = 3, active = 6, playful = 1, nice = 5 },
        interests = { computers = 8, science = 7, money = 6, weather = 2 },
        skills = { cooking = 2, mechanical = 3, logic = 5, body = 2 },
        needs = needs(35, 30, 40, 50, 10, 15, 20, -30), starterJob = { track = "technical", level = 2 } },
    p_gus = { name = "Gus Pemberton", age = "adult", pronoun = "he",
        bio = "Bass player in three bands, two of which exist. Leaves mugs where inspiration struck.",
        look = look({ skin = "porcelain", hair = "copper", style = "long", body = "average", face = 6,
            everyday = { "hoodie_shorts", 9, 9, 9 }, sleep = { "tee_shorts", 9, 2, 8 }, swim = { "trunks", 9, 9, 8 },
            work = { "tee_jeans", 9, 2, 9 }, formal = { "suit", 9, 9, 9 } }),
        personality = { neat = 0, outgoing = 8, active = 3, playful = 10, nice = 4 },
        interests = { music = 10, films = 6, fashion = 3, travel = 5 },
        skills = { creativity = 5, charisma = 3 },
        needs = needs(10, 20, 15, -25, 45, 40, 30, -10), starterJob = { track = "entertainment", level = 1 } },
    p_mo = { name = "Mo Adeyemi", age = "adult", pronoun = "he",
        bio = "Trainee line cook with the confidence of a head chef and the knife skills of a spoon.",
        look = look({ skin = "walnut", hair = "black", style = "buzz", body = "broad", face = 4,
            everyday = { "tee_jeans", 5, 2, 12 }, sleep = { "pajamas", 5, 5, 8 }, swim = { "trunks", 6, 6, 8 },
            work = { "apron", 8, 8, 9 }, formal = { "suit", 2, 2, 9 } }),
        personality = { neat = 2, outgoing = 8, active = 6, playful = 4, nice = 5 },
        interests = { cooking = 10, sports = 6, music = 4, pets = 3 },
        skills = { cooking = 0, charisma = 2, body = 2 },
        needs = needs(45, 35, 30, 20, 30, 45, 25, -10), starterJob = { track = "culinary", level = 1 } },
    -- Ashcombe (2 Alder Row)
    p_vivian = { name = "Vivian Ashcombe", age = "adult", pronoun = "she",
        bio = "Vice president of something with three initials. Answers email in the bath.",
        look = look({ skin = "ebony", hair = "black", style = "bob", body = "slim", face = 4,
            everyday = { "blouse_skirt", 8, 9, 9 }, sleep = { "nightgown", 8, 8, 8 }, swim = { "two_piece", 4, 4, 8 },
            work = { "blazer", 9, 9, 9 }, formal = { "gown", 4, 4, 9 } }),
        personality = { neat = 9, outgoing = 6, active = 7, playful = 0, nice = 3 },
        interests = { money = 9, fashion = 7, travel = 6, sports = 3 },
        skills = { charisma = 6, logic = 5, body = 3, cooking = 1 },
        needs = needs(20, 15, 30, 45, -35, 5, 30, 40), starterJob = { track = "business", level = 5 } },
    p_laurence = { name = "Laurence Ashcombe", age = "adult", pronoun = "he",
        bio = "Collects paintings, clocks and apologies for missing dinner. Cooks beautifully for one.",
        look = look({ skin = "shell", hair = "grey", style = "short", body = "average", face = 5,
            everyday = { "sweater_slacks", 11, 2, 3 }, sleep = { "pajamas", 2, 2, 8 }, swim = { "trunks", 2, 2, 8 },
            work = { "shirt_tie", 8, 11, 9 }, formal = { "suit", 2, 2, 9 } }),
        personality = { neat = 7, outgoing = 3, active = 2, playful = 5, nice = 8 },
        interests = { art = 9, cooking = 7, books = 6, money = 4 },
        skills = { cooking = 4, creativity = 4, logic = 5, charisma = 2 },
        needs = needs(30, 10, 35, 40, -20, -20, 35, 40), starterJob = { track = "technical", level = 4 } },
    -- household bin
    p_ottilie = { name = "Ottilie Marlowe", age = "adult", pronoun = "she",
        bio = "Retired schoolteacher, champion of the parish marrow show, fond of long visits.",
        look = look({ skin = "shell", hair = "white", style = "bun", body = "average", face = 2,
            everyday = { "cardigan_dress", 10, 10, 3 }, sleep = { "nightgown", 8, 8, 8 }, swim = { "one_piece", 12, 12, 8 },
            work = { "cardigan_dress", 10, 10, 3 }, formal = { "gown", 7, 7, 9 } }),
        personality = { neat = 6, outgoing = 7, active = 2, playful = 3, nice = 7 },
        interests = { gardening = 10, townnews = 8, cooking = 5 },
        skills = { cooking = 5, creativity = 3, charisma = 4 },
        needs = needs(40, 35, 40, 50, 30, 20, 30, 30) },
    p_bram = { name = "Bram Marlowe", age = "adult", pronoun = "he",
        bio = "Retired bus driver who still waves at buses. Tells the same three jokes, improved each time.",
        look = look({ skin = "shell", hair = "grey", style = "bald", body = "broad", face = 6,
            everyday = { "overalls", 12, 2, 3 }, sleep = { "pajamas", 12, 12, 8 }, swim = { "trunks", 6, 6, 8 },
            work = { "coveralls", 11, 11, 3 }, formal = { "vest", 3, 3, 9 } }),
        personality = { neat = 3, outgoing = 2, active = 4, playful = 8, nice = 8 },
        interests = { travel = 8, weather = 7, films = 4 },
        skills = { mechanical = 5, charisma = 3 },
        needs = needs(35, 30, 20, 40, 40, 30, 35, 30) },
    p_kenji = { name = "Kenji Sato", age = "adult", pronoun = "he",
        bio = "Personal trainer, morning person, owner of eleven water bottles and no furniture.",
        look = look({ skin = "honey", hair = "black", style = "short", body = "broad", face = 3,
            everyday = { "hoodie_shorts", 1, 9, 8 }, sleep = { "tee_shorts", 11, 9, 8 }, swim = { "shorty", 9, 9, 8 },
            work = { "hoodie_shorts", 4, 9, 8 }, formal = { "suit", 9, 9, 9 } }),
        personality = { neat = 5, outgoing = 2, active = 8, playful = 7, nice = 3 },
        interests = { sports = 10, cooking = 4, travel = 5 },
        skills = { body = 6, charisma = 1 },
        needs = needs(35, 50, 30, 30, 20, 0, 30, 30), starterJob = { track = "sport", level = 2 } },
    p_leona = { name = "Leona Finch", age = "adult", pronoun = "she",
        bio = "Dana's younger sister: louder, later and much more fun at weddings. Starting over with Toby.",
        look = look({ skin = "sand", hair = "golden", style = "long", body = "average", face = 4,
            everyday = { "tee_jeans", 10, 2, 9 }, sleep = { "tee_shorts", 10, 10, 8 }, swim = { "two_piece", 10, 10, 8 },
            work = { "shirt_tie", 8, 2, 9 }, formal = { "cocktail", 4, 4, 9 } }),
        personality = { neat = 4, outgoing = 7, active = 5, playful = 7, nice = 2 },
        interests = { fashion = 8, music = 7, travel = 6 },
        skills = { charisma = 4, creativity = 2 },
        needs = needs(25, 30, 30, 30, 25, 30, 30, 30), starterJob = { track = "civic", level = 1 } },
    p_toby = { name = "Toby Finch", age = "child", pronoun = "he",
        bio = "Seven, a collector of stones and questions. Idolises his cousin Pip.",
        look = look({ skin = "sand", hair = "golden", style = "curly", body = "slim", face = 1,
            everyday = { "overalls", 12, 2, 3 }, sleep = { "pajamas", 6, 6, 8 }, swim = { "trunks", 5, 5, 8 },
            work = { "overalls", 12, 2, 3 }, formal = { "vest", 12, 12, 9 } }),
        personality = { neat = 1, outgoing = 6, active = 8, playful = 9, nice = 1 },
        interests = { pets = 9, science = 6, sports = 5 },
        skills = {},
        needs = needs(30, 45, 30, 20, 30, 30, 35, 30) },
}

-- Townies: no household, no lot. Walk-bys, visits, party guests and neighbours.
PM.townies = {
    t_hattie = { name = "Hattie Quill", age = "adult", pronoun = "she",
        bio = "Knows everyone's business and most of their birthdays. Walks the same loop every evening.",
        look = look({ skin = "porcelain", hair = "ash", style = "bob", face = 2, everyday = { "cardigan_dress", 3, 3, 3 } }),
        personality = { neat = 6, outgoing = 8, active = 4, playful = 3, nice = 4 }, interests = { townnews = 10, gardening = 5 },
        needs = needs(40, 40, 40, 40, 40, 40, 40, 30) },
    t_desmond = { name = "Desmond Oyelaran", age = "adult", pronoun = "he",
        bio = "Marathon hopeful, jogs past at speed and waves at the same time, which is a skill.",
        look = look({ skin = "ebony", hair = "black", style = "buzz", body = "slim", face = 3, everyday = { "hoodie_shorts", 4, 9, 8 } }),
        personality = { neat = 3, outgoing = 5, active = 9, playful = 6, nice = 2 }, interests = { sports = 10, weather = 5 },
        needs = needs(40, 40, 40, 40, 40, 40, 40, 30) },
    t_clem = { name = "Clem Bassett", age = "adult", pronoun = "they",
        bio = "Street magician between gigs. Has pulled a coin from behind every ear on Juniper Lane.",
        look = look({ skin = "clay", hair = "teal", style = "afro", face = 4, everyday = { "overalls", 7, 2, 3 } }),
        personality = { neat = 2, outgoing = 4, active = 3, playful = 10, nice = 6 }, interests = { films = 7, music = 6 },
        needs = needs(40, 40, 40, 40, 40, 40, 40, 30) },
    t_rosalind = { name = "Rosalind Achebe-Hart", age = "adult", pronoun = "she",
        bio = "Retired judge who now referees the allotment committee, which is harder.",
        look = look({ skin = "walnut", hair = "grey", style = "short", face = 5, everyday = { "blouse_skirt", 2, 2, 9 } }),
        personality = { neat = 8, outgoing = 6, active = 3, playful = 2, nice = 6 }, interests = { books = 8, gardening = 7 },
        needs = needs(40, 40, 40, 40, 40, 40, 40, 30) },
    t_felix = { name = "Felix Tanaka", age = "adult", pronoun = "he",
        bio = "Delivers pizzas by day and opinions by night. Rates every doorbell in town.",
        look = look({ skin = "honey", hair = "plum", style = "ponytail", face = 1, everyday = { "tee_jeans", 4, 2, 9 } }),
        personality = { neat = 4, outgoing = 9, active = 6, playful = 5, nice = 1 }, interests = { computers = 7, films = 8 },
        needs = needs(40, 40, 40, 40, 40, 40, 40, 30) },
    t_marguerite = { name = "Marguerite Lowell", age = "adult", pronoun = "she",
        bio = "Paints the pond every Tuesday. Every painting is of a different duck.",
        look = look({ skin = "shell", hair = "white", style = "long", face = 2, everyday = { "cardigan_dress", 6, 6, 3 } }),
        personality = { neat = 7, outgoing = 2, active = 2, playful = 4, nice = 10 }, interests = { art = 10, pets = 6 },
        needs = needs(40, 40, 40, 40, 40, 40, 40, 30) },
}

-- Roz's extra premade data (the fixture record itself is kept exactly as it was).
PM.roz = { interests = { money = 6, gardening = 8, townnews = 5, cooking = 3 } }

---------------------------------------------------------------------------
-- Relationship web. family = a's role toward b (SS.Social.SetFamily sets both directions);
-- flag = partner/roommate/friend (both directions); daily/life per direction (a>b, then b>a).
---------------------------------------------------------------------------
PM.relations = {
    -- Halloran
    { "p_dana", "p_theo", family = "spouse", ab = { 35, 60 }, ba = { 45, 65 } },
    { "p_dana", "p_pip", family = "parent", ab = { 30, 70 }, ba = { 25, 60 } },
    { "p_dana", "p_juno", family = "parent", ab = { 35, 70 }, ba = { 40, 65 } },
    { "p_theo", "p_pip", family = "parent", ab = { 40, 70 }, ba = { 45, 65 } },
    { "p_theo", "p_juno", family = "parent", ab = { 30, 70 }, ba = { 20, 55 } },
    { "p_pip", "p_juno", family = "sibling", ab = { 10, 35 }, ba = { -5, 30 } },
    -- Flatshare: the tidy/messy tension lives in Priya's feelings for Gus
    { "p_priya", "p_gus", family = "roommate", ab = { -30, -10 }, ba = { 15, 20 } },
    { "p_priya", "p_mo", family = "roommate", ab = { 15, 10 }, ba = { 25, 20 } },
    { "p_gus", "p_mo", family = "roommate", ab = { 30, 25 }, ba = { 30, 25 } },
    -- Ashcombe: married, fond, never home at the same time
    { "p_vivian", "p_laurence", family = "spouse", ab = { 15, 55 }, ba = { 15, 60 } },
    -- Marlowe (bin) and the family ties across households
    { "p_ottilie", "p_bram", family = "spouse", ab = { 60, 80 }, ba = { 55, 80 } },
    { "p_ottilie", "p_laurence", family = "parent", ab = { 40, 70 }, ba = { 10, 55 } },
    { "p_bram", "p_laurence", family = "parent", ab = { 45, 70 }, ba = { 20, 60 } },
    { "p_leona", "p_toby", family = "parent", ab = { 50, 80 }, ba = { 45, 75 } },
    { "p_dana", "p_leona", family = "sibling", ab = { 5, 40 }, ba = { 20, 45 } },
    { "p_pip", "p_toby", flag = "friend", ab = { 20, 15 }, ba = { 50, 30 } },
    -- neighbours and friends
    -- Roz knows her neighbours but has no friends yet (her problem is getting people round)
    { "r1", "p_theo", ab = { 25, 30 }, ba = { 20, 25 } },
    { "r1", "p_mo", ab = { 10, 5 }, ba = { 20, 10 } },
    { "r1", "t_hattie", ab = { 5, 10 }, ba = { 25, 15 } },
    { "p_priya", "p_kenji", ab = { 10, 5 }, ba = { 15, 5 } },
    { "p_gus", "t_clem", flag = "friend", ab = { 35, 30 }, ba = { 30, 25 } },
    { "p_laurence", "t_marguerite", flag = "friend", ab = { 30, 35 }, ba = { 35, 35 } },
    { "p_vivian", "t_rosalind", ab = { 10, 20 }, ba = { -10, 5 } },
    { "p_mo", "t_felix", flag = "friend", ab = { 25, 20 }, ba = { 20, 15 } },
    { "p_juno", "t_marguerite", ab = { 15, 10 }, ba = { 20, 15 } },
    { "t_desmond", "p_kenji", ab = { 20, 15 }, ba = { 10, 10 } },
}
