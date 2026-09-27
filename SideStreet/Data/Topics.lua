-- Conversation topics and interests (social module).
-- A person's interests are saved as person.interests = { [topicId] = 0..10 } (0-2 hated,
-- 3-6 indifferent, 7-10 loved). Topics drive topic interactions, acceptance, balloon icons and
-- the topic_love / topic_hate lines. Each topic names the balloon icon the renderer draws
-- (SS.Art.icons[icon]; missing art falls back to a placeholder, see docs/art_requests/social.md).
--   lean  = personality dimensions that make a default interest in this topic more likely
--           (used when a person has no saved interests, and by the creator's randomiser)
--   kid   = children can hold and discuss this interest
--   noun  = how the topic reads mid-sentence ("talking about {topic}")
local _, SS = ...

SS.Topics = {
    list = {
        { id = "sports",    name = "Sports",     noun = "sports",           icon = "topic_sports",    kid = true,  lean = { active = 1.0, outgoing = 0.4 },
          blurb = "Scores, stretches and strongly held opinions about referees." },
        { id = "cooking",   name = "Cooking",    noun = "cooking",          icon = "topic_cooking",   kid = false, lean = { neat = 0.6, nice = 0.5 },
          blurb = "Recipes, knife skills and the eternal question of how much garlic is too much." },
        { id = "music",     name = "Music",      noun = "music",            icon = "topic_music",     kid = true,  lean = { playful = 0.6, outgoing = 0.5 },
          blurb = "Bands nobody else has heard of and the one song that is stuck in their head." },
        { id = "travel",    name = "Travel",     noun = "travel",           icon = "topic_travel",    kid = false, lean = { outgoing = 0.8, active = 0.4 },
          blurb = "Places they have been, places they will go, and the airport sandwich that changed them." },
        { id = "pets",      name = "Pets",       noun = "pets",             icon = "topic_pets",      kid = true,  lean = { nice = 0.9, playful = 0.3 },
          blurb = "Every animal is the best animal. Photographs are available on request." },
        { id = "money",     name = "Money",      noun = "money",            icon = "topic_money",     kid = false, lean = { neat = 0.5, nice = -0.4 },
          blurb = "Savings, spending and a quiet panic about the electricity bill." },
        { id = "fashion",   name = "Fashion",    noun = "fashion",          icon = "topic_fashion",   kid = false, lean = { outgoing = 0.8, neat = 0.4 },
          blurb = "Colours, collars and who wore what to the street party." },
        { id = "films",     name = "Films",      noun = "films",            icon = "topic_films",     kid = true,  lean = { playful = 0.7, active = -0.4 },
          blurb = "Plot twists, sequels, and who was secretly the villain all along." },
        { id = "science",   name = "Science",    noun = "science",          icon = "topic_science",   kid = true,  lean = { playful = -0.6, neat = 0.3 },
          blurb = "Planets, particles and why toast lands butter side down." },
        { id = "gardening", name = "Gardening",  noun = "gardening",        icon = "topic_gardening", kid = false, lean = { neat = 0.5, nice = 0.5, active = 0.2 },
          blurb = "Soil, slugs and the long, silent war with the neighbour's hedge." },
        { id = "townnews",  name = "Town News",  noun = "the local news",   icon = "topic_townnews",  kid = false, lean = { outgoing = 0.9, playful = -0.2 },
          blurb = "Who moved in, who moved out, and what happened to the bus shelter." },
        { id = "art",       name = "Art",        noun = "art",              icon = "topic_art",       kid = true,  lean = { playful = 0.4, neat = -0.4 },
          blurb = "Paintings, sculptures and whether a chair can be a statement." },
        { id = "computers", name = "Computers",  noun = "computers",        icon = "topic_computers", kid = true,  lean = { active = -0.7, outgoing = -0.5 },
          blurb = "Modems, games and the ancient art of turning it off and on again." },
        { id = "weather",   name = "Weather",    noun = "the weather",      icon = "topic_weather",   kid = true,  lean = { nice = 0.3, playful = -0.3 },
          blurb = "Clouds, forecasts and whether it will rain on the washing. Safe ground for strangers." },
        { id = "books",     name = "Books",      noun = "books",            icon = "topic_books",     kid = true,  lean = { playful = -0.5, active = -0.5, outgoing = -0.3 },
          blurb = "Novels, library fines and the book they have been 'nearly finished' with for a year." },
        { id = "games",     name = "Games",      noun = "games",            icon = "topic_games",     kid = true,  lean = { playful = 1.0 },
          blurb = "Board games, card games and the family argument that ended board-game evenings for good." },
    },
    byId = {},
}
for n, t in ipairs(SS.Topics.list) do t.order = n; SS.Topics.byId[t.id] = t end

-- Interest thresholds shared by conversation, lines and UI.
SS.Topics.LOVE, SS.Topics.HATE = 7, 2
