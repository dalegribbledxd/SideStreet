SideStreet 0.2.0 (built 2026-09-27)
====================================

What is in this zip
- SideStreet\  the whole addon folder: game code, the new art (TGA sheets) and the core
  soundtrack (10 music tracks, 12 cues, 3 UI clicks).
- Data\Audio.lua already lists everything in sidestreet_manifest.json, including the 105
  extras. The extras' files are not in this zip; they come from your PC (step 2).

Staging (D:\ForeverWork)
1. Unzip, then put the SideStreet folder at D:\ForeverWork\SideStreet.
2. Copy the audio in from D:\ForeverWork\SideStreetAudio:
   - the 22 ss_*.ogg core files -> D:\ForeverWork\SideStreet\Media\Audio\ (overwrite; these
     are your stereo-fixed re-renders)
   - the extras\ folder -> D:\ForeverWork\SideStreet\Media\Audio\extras\ (105 files)
   Do not edit Data\Audio.lua or Audio\Director.lua; they already match the manifest.
   If an extra is missing, the game plays another variant or the core track instead.

Installing (only when you decide to)
- Replace the whole folder ...\Interface\AddOns\SideStreet with the staged one. Do not copy
  it over the 0.1.0 folder.
- Your 0.1.0 save migrates to the new neighbourhood format when it loads. That is tested
  offline, not yet in your client.

Good to know
- Art ships as TGA only (about 1.4 GB unpacked). The BLP copies are not included, so keep
  /sidestreet art on tga.
- Audio: a stereo or radio that is on plays its station (Classical, Country, Latin and Rock
  use the extras; Pop and Jazz use the core radio tracks). Someone playing the piano plays
  pieces for their creativity level. Life events play short stings.
- Status: tested outside the client (4,300+ offline checks in real Lua 5.1 against a WoW
  mock, plus rendered previews). Not yet tested in the client.
