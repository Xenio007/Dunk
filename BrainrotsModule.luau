-- Saved by UniversalSynSaveInstance (Join to Copy Games) https://discord.gg/wx4ThpAsmw

-- Decompiled with Konstant V2.1, a fast Luau decompiler made in Luau by plusgiant5 (https://discord.gg/brNTY8nX8t)
-- Decompiled on 2026-04-04 17:49:14
-- Luau version 6, Types version 3
-- Time taken: 0.071399 seconds

-- KONSTANTWARNING: Variable analysis failed. Output will have some incorrect variable assignments
local module_upvr_2 = {}
local module_upvr = require(game.ReplicatedStorage:WaitForChild("VariantsModule"))
local function formatCommas_upvr(arg1) -- Line 4, Named "formatCommas"
	local any_match_result1, any_match_result2 = arg1:match("^(.-)(%d+)$")
	if not any_match_result2 then
		return arg1
	end
	return any_match_result1..any_match_result2:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
end
local tbl_2_upvr = {
	-- COMMON
	["Lirili Larila"] = {
		RarityType = "Common";
		CashPerSecond = 1;
		sound = 77891869376009;
		Type = "None";
	};
	["Trippi Troppi"] = {
		RarityType = "Common";
		CashPerSecond = 2;
		Type = "Water";
	};
	["Fluri Flura"] = {
		RarityType = "Common";
		CashPerSecond = 3;
		Sound = 80000126760005;
		Type = "Air";
	};
	["Pipi Kiwi"] = {
		RarityType = "Common";
		CashPerSecond = 3;
		Sound = 71601461350866;
		Type = "None";
	};
	["Svinina Bombardino"] = {
		RarityType = "Common";
		CashPerSecond = 4;
		Type = "None";
	};
	["Brr Brr Patapim"] = {
		RarityType = "Common";
		CashPerSecond = 5;
		Sound = 135871919265006;
		Type = "None";
	};

	-- UNCOMMON
	["Boneca Ambalabu"] = {
		RarityType = "Uncommon";
		CashPerSecond = 6;
		Sound = 82401058692450;
		Type = "None";
	};
	["Cacto Hipopotamo"] = {
		RarityType = "Uncommon";
		CashPerSecond = 7;
		Sound = 74500886543413;
		Type = "Water";
	};
	["Chimpanzini Bananini"] = {
		RarityType = "Uncommon";
		CashPerSecond = 15;
		Sound = 112519317017452;
		Type = "None";
	};
	["Frigo Camelo"] = {
		RarityType = "Uncommon";
		CashPerSecond = 17;
		Sound = 116835658278935;
		Type = "None";
	};
	["Burbaloni Luliloli"] = {
		RarityType = "Uncommon";
		CashPerSecond = 17;
		Type = "None";
	};
	["Talpa Di Fero"] = {
		RarityType = "Uncommon";
		CashPerSecond = 18;
		Sound = 131634462757729;
		Type = "None";
	};

	-- RARE
	["Ta Ta Ta Ta Sahur"] = {
		RarityType = "Rare";
		CashPerSecond = 19;
		Sound = 93276839353990;
		Type = "None";
	};
	["Tung Sahur"] = {
		RarityType = "Rare";
		CashPerSecond = 22;
		Type = "None";
	};
	["Trippi Troppi Troppa Trippa"] = {
		RarityType = "Rare";
		CashPerSecond = 22;
		Type = "Water";
	};
	["Bobrito Bandito"] = {
		RarityType = "Rare";
		CashPerSecond = 26;
		Type = "None";
	};
	["Trulimero Trulicina"] = {
		RarityType = "Rare";
		CashPerSecond = 40;
		Type = "Water";
	};
	["Madudung"] = {
		RarityType = "Rare";
		CashPerSecond = 44;
		Type = "None";
	};
	["Bananita Dolphinita"] = {
		RarityType = "Rare";
		CashPerSecond = 50;
		Sound = 101537516366475;
		Type = "Water";
	};

	-- EPIC
	["Rhino Toasterino"] = {
		RarityType = "Epic";
		CashPerSecond = 52;
		Type = "None";
	};
	["Orangutini Ananassini"] = {
		RarityType = "Epic";
		CashPerSecond = 62;
		Sound = 78995795448312;
		Type = "None";
	};
	["Odin Din Din Dun"] = {
		RarityType = "Epic";
		CashPerSecond = 64;
		Sound = 75909188172661;
		Type = "None";
	};
	["Cappuccino Assassino"] = {
		RarityType = "Epic";
		CashPerSecond = 64;
		Sound = 132507332049936;
		Type = "None";
	};
	["Brri Brri Bicus Dicus"] = {
		RarityType = "Epic";
		CashPerSecond = 72;
		Type = "Air";
	};
	["Glorbo Fruttodrillo"] = {
		RarityType = "Epic";
		CashPerSecond = 76;
		Type = "Water";
	};
	["Bambini Crostini"] = {
		RarityType = "Epic";
		CashPerSecond = 100;
		Sound = 104910822169397;
		Type = "None";
	};
	["Avocadini Guffo"] = {
		RarityType = "Epic";
		CashPerSecond = 130;
		Sound = 103382838997945;
		Type = "Air";
	};
	["Gangster Footera"] = {
		RarityType = "Epic";
		CashPerSecond = 150;
		Sound = 123260834395862;
		Type = "None";
	};
	["Tric Trac Barabum"] = {
		RarityType = "Epic";
		CashPerSecond = 160;
		Type = "None";
		Craft = true;
	};

	-- LEGENDARY
	["Six Seven"] = {
		RarityType = "Legendary";
		CashPerSecond = 170;
		Type = "None";
	};
	["Ballerina Cappuccina"] = {
		RarityType = "Legendary";
		CashPerSecond = 210;
		Sound = 75920015995036;
		Type = "None";
	};
	["Chef Crabracadabra"] = {
		RarityType = "Legendary";
		CashPerSecond = 230;
		Sound = 71037632336586;
		Type = "Water";
	};
	["Strawberrelli Flamingelli"] = {
		RarityType = "Legendary";
		CashPerSecond = 450;
		Type = "Water";
	};
	["Pandaccini Bananini"] = {
		RarityType = "Legendary";
		CashPerSecond = 500;
		Type = "None";
	};
	["Matteo"] = {
		RarityType = "Legendary";
		CashPerSecond = 550;
		soud = 105593983925243;
		Type = "None";
	};
	["Garamararam"] = {
		RarityType = "Uncommon";
		CashPerSecond = 600;
		Type = "None";
	};
	["Pipi Potato"] = {
		RarityType = "Legendary";
		CashPerSecond = 650;
		Sound = 105473512117858;
		Type = "None";
	};
	["Blueberrinni Octopusini"] = {
		RarityType = "Legendary";
		CashPerSecond = 725;
		Type = "None";
	};
	["Lionel Cactuseli"] = {
		RarityType = "Legendary";
		CashPerSecond = 880;
		Type = "None";
		Craft = true;
	};

	-- Mythic	
	["Bombombini Gusini"] = {
		RarityType = "Mythic";
		CashPerSecond = 1200;
		Type = "Air";
	};
	["Bombardiro Crocodilo"] = {
		RarityType = "Mythic";
		CashPerSecond = 1500;
		Sound = 95943432024838;
		Type = "Air";
	};
	["Cocofanto Elefanto"] = {
		RarityType = "Mythic";
		CashPerSecond = 1800;
		Sound = 87797644986207;
		Type = "None";
	};
	["Girafa Celeste"] = {
		RarityType = "Mythic";
		CashPerSecond = 2000;
		Type = "None";
	};
	["Tralalero Tralala"] = {
		RarityType = "Mythic";
		CashPerSecond = 2100;
		Type = "Water";
	};
	["Orcalero Orcala"] = {
		RarityType = "Mythic";
		CashPerSecond = 2300;
		Sound = 74663192527667;
		Type = "Water";
	};
	["Cavallo Virtuoso"] = {
		RarityType = "Mythic";
		CashPerSecond = 2400;
		Sound = 73020523239902;
		Type = "None";
	};
	["Zibra Zubra Zibralini"] = {
		RarityType = "Mythic";
		CashPerSecond = 2600;
		Type = "None";
	};
	["Ballerino Lololo"] = {
		RarityType = "Mythic";
		CashPerSecond = 2700;
		Sound = 90615826545406;
		Type = "None";
	};
	["Gorillo Watermelondrillo"] = {
		RarityType = "Mythic";
		CashPerSecond = 3100;
		Type = "None";
	};
	["Lerulerulerule"] = {
		RarityType = "Mythic";
		CashPerSecond = 3800;
		Type = "None";
	};
	["Ganganzelli Trulala"] = {
		RarityType = "Mythic";
		CashPerSecond = 5000;
		Type = "None";
		Craft = true;
	};
	["Tralaledon"] = {
		RarityType = "Mythic";
		CashPerSecond = 5300;
		Sound = 88039936104979;
		Type = "Water";
		Craft = true;
	};
	["Ranocchio Del Tesoro"] = {
		RarityType = "Mythic";
		CashPerSecond = 5800;
		Type = "None";
	};
	["Pinguino Pentadagoro"] = {
		RarityType = "Mythic";
		CashPerSecond = 6200;
		Type = "None";
	};

	-- SECRET
	["La Vacca Saturno Saturnita"] = {
		RarityType = "Secret";
		CashPerSecond = 12500;
		Sound = 112547585357624;
		Type = "None";
	};
	["Pot Hotspot"] = {
		RarityType = "Secret";
		CashPerSecond = 15000;
		Sound = 95702090303397;
		Type = "None";
	};
	["Los Tralaleritos"] = {
		RarityType = "Secret";
		CashPerSecond = 16500;
		Type = "Water";
	};
	["Dragon Cannelloni"] = {
		RarityType = "Secret";
		CashPerSecond = 17500;
		Type = "Air";
	};
	["Esok Sekolah"] = {
		RarityType = "Secret";
		CashPerSecond = 18000;
		Type = "None";
	};
	["Job Job Job Sahur"] = {
		RarityType = "Secret";
		CashPerSecond = 19500;
		Sound = 114789751098685;
		Type = "None";
	};
	["Agarrini La Pallini"] = {
		RarityType = "Secret";
		CashPerSecond = 20000;
		Sound = 138776715308355;
		Type = "None";
	};
	["Karkerkar Kurkur"] = {
		RarityType = "Secret";
		CashPerSecond = 22500;
		Sound = 95172518463267;
		Type = "None";
	};
	["Tralalita Tralala"] = {
		RarityType = "Secret";
		CashPerSecond = 23000;
		Type = "Water";
	};
	["Torrtuginni Dragonfrutini"] = {
		RarityType = "Secret";
		CashPerSecond = 25000;
		Type = "None";
	};
	["Espresso Signora"] = {
		RarityType = "Secret";
		CashPerSecond = 27500;
		Type = "None";
	};
	["Wristini Rizzini"] = {
		RarityType = "Secret";
		CashPerSecond = 27500;
		Type = "None";
	};
	["Strawberry Elephant"] = {
		RarityType = "Secret";
		CashPerSecond = 29000;
		Sound = 136740327125910;
		Type = "None";
	};
	["La Grande Combinasion"] = {
		RarityType = "Secret";
		CashPerSecond = 32000;
		Sound = 90200622604338;
		Type = "None";
		Craft = true;
	};
	["Triplito Tralaleritos"] = {
		RarityType = "Secret";
		CashPerSecond = 38000;
		Type = "Water";
		Craft = true;
	};

	-- GOD
	["Tigroligre Frutonni"] = {
		RarityType = "God";
		CashPerSecond = 44500;
		Type = "None";
	};
	["Pakrahmatmamat"] = {
		RarityType = "God";
		CashPerSecond = 44500;
		Type = "None";
	};
	["Pakrahmatmatina"] = {
		RarityType = "God";
		CashPerSecond = 49500;
		Type = "None";
	};
	["Chicleteira Bicicleteira"] = {
		RarityType = "God";
		CashPerSecond = 53500;
		Type = "None";
	};
	["Cachorrito Melonito"] = {
		RarityType = "God";
		CashPerSecond = 75000;
		Sound = 74465213728123;
		Type = "None";
	};
	["Noo My Examen"] = {
		RarityType = "God";
		CashPerSecond = 95000;
		Type = "None";
	};
	["Yess My Examen"] = {
		RarityType = "God";
		CashPerSecond = 120000;
		Type = "None";
	};
	["Chestini Tralalero"] = {
		RarityType = "God";
		CashPerSecond = 135000;
		Type = "None";
	};
	["Chicleteirina Bicicleteirina"] = {
		RarityType = "God";
		CashPerSecond = 220000;
		Type = "Water";
		Craft = true;
	};
	["Chillin Chili"] = {
		RarityType = "God";
		CashPerSecond = 225000;
		Sound = 115908712609093;
		Type = "None";
		Craft = true;
	};
	["Swag Soda"] = {
		RarityType = "God";
		CashPerSecond = 225000;
		Sound = 98007776828620;
		Type = "None";
		Craft = true;
	};
	["W Or L"] = {
		RarityType = "God";
		CashPerSecond = 275000;
		Type = "None";
		Craft = true;
	};
	["Teddino Rosino"] = {
		RarityType = "God";
		CashPerSecond = 350000;
		Type = "None";
	};
	["Love Love Love Sahur"] = {
		RarityType = "God";
		CashPerSecond = 420000;
		Type = "None";
	};
	["Pakrahmatmatina Valentina"] = {
		RarityType = "God";
		CashPerSecond = 475000;
		Type = "None";
	};
	["Noo My Heart"] = {
		RarityType = "God";
		CashPerSecond = 500000;
		Type = "None";
	};

	-- OG
	["Banana Dancana"] = {
		RarityType = "OG";
		CashPerSecond = 525000;
		Type = "None";
	};
	["Illuminato Triangolo"] = {
		RarityType = "OG";
		CashPerSecond = 540000;
		Type = "None";
	};
	["Nyannini Cattalini"] = {
		RarityType = "OG";
		CashPerSecond = 575000;
		Type = "None";
	};
	["Bananini Kittini"] = {
		RarityType = "OG";
		CashPerSecond = 625000;
		Type = "None";
	};
	["Meowl"] = {
		RarityType = "OG";
		CashPerSecond = 750000;
		Sound = 125621644257669;
		Type = "None";
	};
	["Smurfo Gatto"] = {
		RarityType = "OG";
		CashPerSecond = 800000;
		Type = "None";
	};
	["Skrrtini Driftini"] = {
		RarityType = "OG";
		CashPerSecond = 850000;
		Type = "None";
	};
	["La Cucaracha"] = {
		RarityType = "OG";
		CashPerSecond = 1000000;
		Type = "None";
		Fuse = false;
	};
}
local tbl = {
	["Agarrini La Pallini"] = "rbxassetid://119960901071530";
	["Ballerina Cappuccina"] = "rbxassetid://138615997586774";
	["Ballerino Lololo"] = "rbxassetid://131941660341640";
	["Bananita Dolphinita"] = "rbxassetid://125393527414559";
	["Bobrito Bandito"] = "rbxassetid://100975638214483";
	["Boneca Ambalabu"] = "rbxassetid://87060640403512";
	["Bombardiro Crocodilo"] = "rbxassetid://109146139727139";
	["Bombombini Gusini"] = "rbxassetid://93633123318384";
	["Brri Brri Bicus Dicus"] = "rbxassetid://81246183054144";
	["Brr Brr Patapim"] = "rbxassetid://84193682750445";
	["Burbaloni Luliloli"] = "rbxassetid://118303183480599";
	["Cacto Hipopotamo"] = "rbxassetid://85778694198750";
	["Cappuccino Assassino"] = "rbxassetid://93151728232405";
	["Cavallo Virtuoso"] = "rbxassetid://91990976978161";
	["Chef Crabracadabra"] = "rbxassetid://130843868905157";
	["Chimpanzini Bananini"] = "rbxassetid://135804738860885";
	["Cocofanto Elefanto"] = "rbxassetid://90200524490457";
	["Dragon Cannelloni"] = "rbxassetid://115970447630902";
	["Esok Sekolah"] = "rbxassetid://74907657930419";
	["Fluri Flura"] = "rbxassetid://106072330223609";
	["Frigo Camelo"] = "rbxassetid://119031445104683";
	["Gangster Footera"] = "rbxassetid://121768816801900";
	["Garamararam"] = "rbxassetid://103700238368791";
	["Girafa Celeste"] = "rbxassetid://97493978039652";
	["Glorbo Fruttodrillo"] = "rbxassetid://99413861323667";
	["Job Job Job Sahur"] = "rbxassetid://125741754730832";
	["Karkerkar Kurkur"] = "rbxassetid://103845028555133";
	["La Vacca Saturno Saturnita"] = "rbxassetid://92985101252540";
	["Lirili Larila"] = "rbxassetid://96517608886723";
	["Los Tralaleritos"] = "rbxassetid://137931860036968";
	["Madudung"] = "rbxassetid://117380790347663";
	["Matteo"] = "rbxassetid://93666784792688";
	["Odin Din Din Dun"] = "rbxassetid://97618493990610";
	["Orangutini Ananassini"] = "rbxassetid://134808357981370";
	["Orcalero Orcala"] = "rbxassetid://138874619901011";
	["Pandaccini Bananini"] = "rbxassetid://137264963408399";
	["Pipi Kiwi"] = "rbxassetid://116801770352293";
	["Pot Hotspot"] = "rbxassetid://110842727450626";
	["Rhino Toasterino"] = "rbxassetid://125661120786562";
	["Six Seven"] = "rbxassetid://136494980830684";
	["Strawberrelli Flamingelli"] = "rbxassetid://128337067811503";
	["Strawberry Elephant"] = "rbxassetid://109289743907806";
	["Svinina Bombardino"] = "rbxassetid://132984358025514";
	["Ta Ta Ta Ta Sahur"] = "rbxassetid://126208919936860";
	["Tralalero Tralala"] = "rbxassetid://115965086679865";
	["Trippi Troppi"] = "rbxassetid://78453817904722";
	["Trippi Troppi Troppa Trippa"] = "rbxassetid://89405728027542";
	["Trulimero Trulicina"] = "rbxassetid://126063557709183";
	["Tung Sahur"] = "rbxassetid://77661948625916";
	["Zibra Zubra Zibralini"] = "rbxassetid://93439583730251";
	["Tim Cheese"] = "rbxassetid://123085126504398";
	["Talpa Di Fero"] = "rbxassetid://71892938506811";
	["Bambini Crostini"] = "rbxassetid://119870045910284";
	["Avocadini Guffo"] = "rbxassetid://89015298713721";
	["Blueberrinni Octopusini"] = "rbxassetid://89978505575087";
	["Pipi Potato"] = "rbxassetid://119284824719272";
	["Gorillo Watermelondrillo"] = "rbxassetid://98983904785631";
	["Lerulerulerule"] = "rbxassetid://95583740505568";
	["Tigroligre Frutonni"] = "rbxassetid://139820365436789";
	["Tralalita Tralala"] = "rbxassetid://84480007765954";
	["Pakrahmatmamatv"] = "rbxassetid://117605897411348";
	["Torrtuginni Dragonfrutini"] = "rbxassetid://106715652688464";
	["Espresso Signora"] = "rbxassetid://91819021257366";
	["Chicleteira Bicicleteira"] = "rbxassetid://133847593115197";
	["Pakrahmatmatina"] = "rbxassetid://135520049239372";
	["Tric Trac Barabum"] = "rbxassetid://134033024238079";
	["Lionel Cactuseli"] = "rbxassetid://105223395131616";
	["Ganganzelli Trulala"] = "rbxassetid://78977970544336";
	["Swag Soda"] = "rbxassetid://76419042633668";
	["Chillin Chili"] = "rbxassetid://92830193182791";
	["La Grande Combinasion"] = "rbxassetid://121304395508496";
	["Tralaledon"] = "rbxassetid://120060311319552";
	["Triplito Tralaleritos"] = "rbxassetid://79887610958495";
	["Chicleteirina Bicicleteirina"] = "rbxassetid://78439025995324";
	["Banana Dancana"] = "rbxassetid://97773231142350";
	["Illuminato Triangolo"] = "rbxassetid://113655593349356";
	["Nyannini Cattalini"] = "rbxassetid://106473881175209";
	["Smurfo Gatto"] = "rbxassetid://91565234964597";
	["Bananini Kittini"] = "rbxassetid://113714779789090";
	["Noo My Examen"] = "rbxassetid://107057357696721";
	["Yess My Examen"] = "rbxassetid://108726439882174";
	["Cachorrito Melonito"] = "rbxassetid://93492318324697";
	["W Or L"] = "rbxassetid://135978788833673";
	["1x1x1x1"] = "rbxassetid://131659670938457";
	["Meowl"] = "rbxassetid://114138541738947";
	["Wristini Rizzini"] = "rbxassetid://135217898791467";
	["Chestini Tralalero"] = "rbxassetid://130284147049083";
	["Skrrtini Driftini"] = "rbxassetid://118108480794631";
	["Pakrahmatmatina Valentina"] = "rbxassetid://134492165319328";
	["Love Love Love Sahur"] = "rbxassetid://131619945495856";
	["Noo My Heart"] = "rbxassetid://106114643672684";
	["Teddino Rosino"] = "rbxassetid://76488293317282";
	["La Cucaracha"] = "rbxassetid://133625725205487";
	["Ranocchio Del Tesoro"] = "rbxassetid://123444558748235";
	["Pinguino Pentadagoro"] = "rbxassetid://113825671631524";
}
for i, v in pairs(tbl_2_upvr) do
	local var143
	if 0 < v.Rarity then
		var143 = math.max(1, math.floor(100000000 / v.Rarity * 2))
	else
		var143 = 0
	end
	local tbl_3 = {
		Rarity = v.Rarity;
		Image = tbl[i];
		RarityType = v.RarityType;
		CashPerSecond = v.CashPerSecond;
		SellPrice = v.CashPerSecond * 15;
	}
	if 0 < var143 then
	else
	end
	tbl_3.FractionChance = '0'
	tbl_3.Type = v.Type
	tbl_3.Fuse = v.Fuse
	module_upvr_2[i] = tbl_3
end
for _, v_2 in ipairs(module_upvr.VARIANTS) do
	local var155 = ({
		["Gold "] = {
			["Agarrini La Pallini"] = "rbxassetid://74148725836626";
			["Ballerina Cappuccina"] = "rbxassetid://74609786842932";
			["Ballerino Lololo"] = "rbxassetid://127784814150948";
			["Bananita Dolphinita"] = "rbxassetid://78552420307472";
			["Bobrito Bandito"] = "rbxassetid://111157806093757";
			["Boneca Ambalabu"] = "rbxassetid://129978621472051";
			["Bombardiro Crocodilo"] = "rbxassetid://99015325287537";
			["Bombombini Gusini"] = "rbxassetid://115604282766739";
			["Brri Brri Bicus Dicus"] = "rbxassetid://77205434540854";
			["Brr Brr Patapim"] = "rbxassetid://89251047527583";
			["Burbaloni Luliloli"] = "rbxassetid://138611306773195";
			["Cacto Hipopotamo"] = "rbxassetid://111965236369143";
			["Cappuccino Assassino"] = "rbxassetid://135786737674153";
			["Cavallo Virtuoso"] = "rbxassetid://126283934098413";
			["Chef Crabracadabra"] = "rbxassetid://116118469153549";
			["Chimpanzini Bananini"] = "rbxassetid://130993068538984";
			["Cocofanto Elefanto"] = "rbxassetid://89647737205022";
			["Dragon Cannelloni"] = "rbxassetid://118425759603818";
			["Esok Sekolah"] = "rbxassetid://105452737814425";
			["Fluri Flura"] = "rbxassetid://100868549014186";
			["Frigo Camelo"] = "rbxassetid://72197665978728";
			["Garamararam" = "rbxassetid://84505801973595";
			["Gangster Footera"] = "rbxassetid://136981476880085";
			["Girafa Celeste"] = "rbxassetid://110781536143880";
			["Glorbo Fruttodrillo"] = "rbxassetid://120895017029745";
			["Job Job Job Sahur"] = "rbxassetid://123519716807094";
			["Karkerkar Kurkur"] = "rbxassetid://70981556467511";
			["La Vacca Saturno Saturnita"] = "rbxassetid://72603570583778";
			["Lirili Larila"] = "rbxassetid://132009533783051";
			["Los Tralaleritos"] = "rbxassetid://72299834842001";
			["Madudung"] = "rbxassetid://71722113336108";
			["Matteo"] = "rbxassetid://131806031890774";
			["Odin Din Din Dun"] = "rbxassetid://113178258183215";
			["Orangutini Ananassini"] = "rbxassetid://92406297139188";
			["Orcalero Orcala"] = "rbxassetid://80196069917573";
			["Pandaccini Bananini"] = "rbxassetid://97747423392096";
			["Pipi Kiwi"] = "rbxassetid://76094522489673";
			["Pot Hotspot"] = "rbxassetid://81307917869525";
			["Rhino Toasterino"] = "rbxassetid://86354279425791";
			["Six Seven"] = "rbxassetid://95926461538602";
			["Strawberrelli Flamingelli"] = "rbxassetid://110225417910332";
			["Strawberry Elephant"] = "rbxassetid://99078174095669";
			["Svinina Bombardino"] = "rbxassetid://97498595596606";
			["Ta Ta Ta Ta Sahur"] = "rbxassetid://123491788157109";
			["Tralalero Tralala"] = "rbxassetid://116632448689537";
			["Trippi Troppi"] = "rbxassetid://78509390443843";
			["Trippi Troppi Troppa Trippa"] = "rbxassetid://103690064612901";
			["Trulimero Trulicina"] = "rbxassetid://98430559027406";
			["Tung Sahur"] = "rbxassetid://78905853037303";
			["Zibra Zubra Zibralini"] = "rbxassetid://94432408597948";
			["Tim Cheese"] = "rbxassetid://75817327238091";
			["Talpa Di Fero"] = "rbxassetid://83098580138731";
			["Bambini Crostini"] = "rbxassetid://104764842477119";
			["Avocadini Guffo"] = "rbxassetid://102871794494847";
			["Blueberrinni Octopusini"] = "rbxassetid://93828472672198";
			["Pipi Potato"] = "rbxassetid://120165877741704";
			["Gorillo Watermelondrillo"] = "rbxassetid://134926441645958";
			["Lerulerulerule"] = "rbxassetid://76351025829662";
			["Tigroligre Frutonni"] = "rbxassetid://107231237004619";
			["Tralalita Tralala"] = "rbxassetid://82499053188415";
			["Pakrahmatmamat"] = "rbxassetid://109372660584704";
			["Torrtuginni Dragonfrutini"] = "rbxassetid://98356315267265";
			["Espresso Signora"] = "rbxassetid://91228422849080";
			["Chicleteira Bicicleteira"] = "rbxassetid://73343054295857";
			["Pakrahmatmatina"] = "rbxassetid://108149147703859";
			["Tric Trac Barabum"] = "rbxassetid://91809320779437";
			["Lionel Cactuseli"] = "rbxassetid://107163277778456";
			["Ganganzelli Trulala"] = "rbxassetid://105160470980607";
			["Swag Soda"] = "rbxassetid://129974990809880";
			["Chillin Chili"] = "rbxassetid://88589271321512";
			["La Grande Combinasion"] = "rbxassetid://76323020169590";
			["Tralaledon"] = "rbxassetid://119375008653403";
			["Triplito Tralaleritos"] = "rbxassetid://72491206637703";
			["Chicleteirina Bicicleteirina"] = "rbxassetid://79602305459769";
			["Banana Dancana"] = "rbxassetid://102635768274369";
			["Illuminato Triangolo"] = "rbxassetid://110269995314069";
			["Nyannini Cattalini"] = "rbxassetid://136464953656974";
			["Smurfo Gatto"] = "rbxassetid://108533953235185";
			["Bananini Kittini"] = "rbxassetid://107999748747779";
			["Noo My Examen"] = "rbxassetid://112804603708995";
			["Yess My Examen"] = "rbxassetid://96596946211622";
			["Cachorrito Melonito"] = "rbxassetid://140391419721635";
			["W Or L"] = "rbxassetid://116802362165757";
			["1x1x1x1"] = "rbxassetid://117817952243254";
			["Meowl"] = "rbxassetid://85773090919644";
			["Wristini Rizzini"] = "rbxassetid://98259172862949";
			["Chestini Tralalero"] = "rbxassetid://88953235687140";
			["Skrrtini Driftini"] = "rbxassetid://74508666224588";
			["Pakrahmatmatina Valentina"] = "rbxassetid://80661751170638";
			["Love Love Love Sahur"] = "rbxassetid://115140018475215";
			["Noo My Heart"] = "rbxassetid://123421785819777";
			["Teddino Rosino"] = "rbxassetid://71250120470866";
			["La Cucaracha"] = "rbxassetid://124034691856261";
			["Ranocchio Del Tesoro"] = "rbxassetid://135010379809725";
			["Pinguino Pentadagoro"] = "rbxassetid://140736713575804";
		};
		["Diamond "] = {
			["Agarrini La Pallini"] = "rbxassetid://130096887211116";
			["Ballerina Cappuccina"] = "rbxassetid://110021766884366";
			["Ballerino Lololo"] = "rbxassetid://79482553594453";
			["Bobrito Bandito"] = "rbxassetid://118448596529099";
			["Bananita Dolphinita"] = "rbxassetid://135523015944221";
			["Boneca Ambalabu"] = "rbxassetid://75267931668936";
			["Bombardiro Crocodilo"] = "rbxassetid://76981766211887";
			["Bombombini Gusini"] = "rbxassetid://126468855366521";
			["Brri Brri Bicus Dicus"] = "rbxassetid://103636306025261";
			["Brr Brr Patapim"] = "rbxassetid://109244302925009";
			["Burbaloni Luliloli"] = "rbxassetid://87043641401739";
			["Cacto Hipopotamo"] = "rbxassetid://117272029981600";
			["Cappuccino Assassino"] = "rbxassetid://102624626972215";
			["Cavallo Virtuoso"] = "rbxassetid://88917839606742";
			["Chef Crabracadabra"] = "rbxassetid://103883109957069";
			["Chimpanzini Bananini"] = "rbxassetid://88363958689260";
			["Cocofanto Elefanto"] = "rbxassetid://72502518863578";
			["Dragon Cannelloni"] = "rbxassetid://107763346020346";
			["Esok Sekolah"] = "rbxassetid://117233850837158";
			["Fluri Flura"] = "rbxassetid://136684116875898";
			["Frigo Camelo"] = "rbxassetid://119138146708156";
			["Garamararam"] = "rbxassetid://83762893624288";
			["Gangster Footera"] = "rbxassetid://120907070178872";
			["Girafa Celeste"] = "rbxassetid://82451618825673";
			["Glorbo Fruttodrillo"] = "rbxassetid://132212557337957";
			["Job Job Job Sahur"] = "rbxassetid://125636296239596";
			["Karkerkar Kurkur"] = "rbxassetid://88720054720651";
			["La Vacca Saturno Saturnita"] = "rbxassetid://76091939640661";
			["Lirili Larila"] = "rbxassetid://84139121125957";
			["Los Tralaleritos"] = "rbxassetid://97343312265227";
			["Madudung"] = "rbxassetid://139936939609977";
			["Matteo"] = "rbxassetid://94344448696184";
			["Odin Din Din Dun"] = "rbxassetid://81096031188456";
			["Orangutini Ananassini"] = "rbxassetid://112251682701595";
			["Orcalero Orcala"] = "rbxassetid://129274481193605";
			["Pandaccini Bananini"] = "rbxassetid://122702294111396";
			["Pipi Kiwi"] = "rbxassetid://105053452207378";
			["Pot Hotspot"] = "rbxassetid://107370480556031";
			["Rhino Toasterino"] = "rbxassetid://88834181818029";
			["Six Seven"] = "rbxassetid://113655056767712";
			["Strawberrelli Flamingelli"] = "rbxassetid://127712395552156";
			["Strawberry Elephant"] = "rbxassetid://138750138959989";
			["Svinina Bombardino"] = "rbxassetid://76409724694387";
			["Ta Ta Ta Ta Sahur"] = "rbxassetid://71704351307700";
			["Tralalero Tralala"] = "rbxassetid://72094226953371";
			["Trippi Troppi"] = "rbxassetid://116593905788691";
			["Trippi Troppi Troppa Trippa"] = "rbxassetid://100409677145043";
			["Trulimero Trulicina"] = "rbxassetid://106483640151758";
			["Tung Sahur"] = "rbxassetid://127121768725469";
			["Zibra Zubra Zibralini"] = "rbxassetid://117893465491698";
			["Tim Cheese"] = "rbxassetid://125036605135212";
			["Talpa Di Fero"] = "rbxassetid://113590448835890";
			["Bambini Crostini"] = "rbxassetid://100191921011891";
			["Avocadini Guffo"] = "rbxassetid://103473321498735";
			["Blueberrinni Octopusini"] = "rbxassetid://108646274606604";
			["Pipi Potato"] = "rbxassetid://112707225293989";
			["Gorillo Watermelondrillo"] = "rbxassetid://71375466689877";
			["Lerulerulerule"] = "rbxassetid://83010353144603";
			["Tigroligre Frutonni"] = "rbxassetid://92054122363738";
			["Tralalita Tralala"] = "rbxassetid://96803458979077";
			["Pakrahmatmamat"] = "rbxassetid://112268702524941";
			["Torrtuginni Dragonfrutini"] = "rbxassetid://98340205051124";
			["Espresso Signora"] = "rbxassetid://97040417709060";
			["Chicleteira Bicicleteira"] = "rbxassetid://84683334278063";
			["Pakrahmatmatina"] = "rbxassetid://106527847298397";
			["Tric Trac Barabum"] = "rbxassetid://133223467385437";
			["Lionel Cactuseli"] = "rbxassetid://83157284238413";
			["Ganganzelli Trulala"] = "rbxassetid://126781951564259";
			["Swag Soda"] = "rbxassetid://112294231059668";
			["Chillin Chili"] = "rbxassetid://136647679241609";
			["La Grande Combinasion"] = "rbxassetid://130331399197509";
			["Tralaledon"] = "rbxassetid://86181366782101";
			["Triplito Tralaleritos"] = "rbxassetid://102865170951035";
			["Chicleteirina Bicicleteirina"] = "rbxassetid://84174089455963";
			["Banana Dancana"] = "rbxassetid://78824921253151";
			["Illuminato Triangolo"] = "rbxassetid://78961528579533";
			["Nyannini Cattalini"] = "rbxassetid://97644184628267";
			["Smurfo Gatto"] = "rbxassetid://72378857128980";
			["Bananini Kittini"] = "rbxassetid://123331301723790";
			["Noo My Examen"] = "rbxassetid://102365209767649";
			["Yess My Examen"] = "rbxassetid://124220618282977";
			["Cachorrito Melonito"] = "rbxassetid://86794095375993";
			["W Or L"] = "rbxassetid://103580657294062";
			["1x1x1x1"] = "rbxassetid://127186136988351";
			["Meowl"] = "rbxassetid://127859122845637";
			["Wristini Rizzini"] = "rbxassetid://126310910102350";
			["Chestini Tralalero"] = "rbxassetid://95214310175292";
			["Skrrtini Driftini"] = "rbxassetid://134971363642006";
			["Pakrahmatmatina Valentina"] = "rbxassetid://85669554245795";
			["Love Love Love Sahur"] = "rbxassetid://90775000903278";
			["Noo My Heart"] = "rbxassetid://103494122096388";
			["Teddino Rosino"] = "rbxassetid://128449694675798";
			["La Cucaracha"] = "rbxassetid://99513197668352";
			["Ranocchio Del Tesoro"] = "rbxassetid://82742523452330";
			["Pinguino Pentadagoro"] = "rbxassetid://117565750316900";
		};
		["Lava "] = {
			["Agarrini La Pallini"] = "rbxassetid://131333423196667";
			["Ballerina Cappuccina"] = "rbxassetid://108222716644178";
			["Ballerino Lololo"] = "rbxassetid://78644725108354";
			["Bobrito Bandito"] = "rbxassetid://87024962692357";
			["Bananita Dolphinita"] = "rbxassetid://89417513055260";
			["Boneca Ambalabu"] = "rbxassetid://118832798630230";
			["Bombardiro Crocodilo"] = "rbxassetid://78700326300363";
			["Bombombini Gusini"] = "rbxassetid://99870953319160";
			["Brri Brri Bicus Dicus"] = "rbxassetid://79747688395514";
			["Brr Brr Patapim"] = "rbxassetid://105086181959528";
			["Burbaloni Luliloli"] = "rbxassetid://140235575485942";
			["Cacto Hipopotamo"] = "rbxassetid://87188649330642";
			["Cappuccino Assassino"] = "rbxassetid://85471027003237";
			["Cavallo Virtuoso"] = "rbxassetid://127470650347208";
			["Chef Crabracadabra"] = "rbxassetid://133340904134787";
			["Chimpanzini Bananini"] = "rbxassetid://71219292011578";
			["Cocofanto Elefanto"] = "rbxassetid://98690578463877";
			["Dragon Cannelloni"] = "rbxassetid://99481751406682";
			["Esok Sekolah"] = "rbxassetid://79486168443795";
			["Fluri Flura"] = "rbxassetid://100156190859675";
			["Frigo Camelo"] = "rbxassetid://71527500037634";
			["Garamararam"] = "rbxassetid://109823001165002";
			["Gangster Footera"] = "rbxassetid://81337372957807";
			["Girafa Celeste"] = "rbxassetid://86593604935327";
			["Glorbo Fruttodrillo"] = "rbxassetid://139814199767661";
			["Job Job Job Sahur"] = "rbxassetid://115612696377412";
			["Karkerkar Kurkur"] = "rbxassetid://86572010343475";
			["La Vacca Saturno Saturnita"] = "rbxassetid://101600627909518";
			["Lirili Larila"] = "rbxassetid://71099306490763";
			["Los Tralaleritos"] = "rbxassetid://133462317837214";
			["Madudung"] = "rbxassetid://102016387321133";
			["Matteo"] = "rbxassetid://140122008146021";
			["Odin Din Din Dun"] = "rbxassetid://78654678303355";
			["Orangutini Ananassini"] = "rbxassetid://127820629362241";
			["Orcalero Orcala"] = "rbxassetid://131315229391713";
			["Pandaccini Bananini"] = "rbxassetid://87729822071295";
			["Pipi Kiwi"] = "rbxassetid://122886492746796";
			["Pot Hotspot"] = "rbxassetid://71281211194605";
			["Rhino Toasterino"] = "rbxassetid://121044295008117";
			["Six Seven"] = "rbxassetid://83995095896867";
			["Strawberrelli Flamingelli"] = "rbxassetid://104105484274028";
			["Strawberry Elephant"] = "rbxassetid://88296238402353";
			["Svinina Bombardino"] = "rbxassetid://125105585122342";
			["Ta Ta Ta Ta Sahur"] = "rbxassetid://111246790423093";
			["Tralalero Tralala"] = "rbxassetid://138509210845299";
			["Trippi Troppi"] = "rbxassetid://128101111380024";
			["Trippi Troppi Troppa Trippa"] = "rbxassetid://108980505951033";
			["Trulimero Trulicina"] = "rbxassetid://108011582858071";
			["Tung Sahur"] = "rbxassetid://103413501375080";
			["Zibra Zubra Zibralini"] = "rbxassetid://95090430686451";
			["Tim Cheese"] = "rbxassetid://123559265141465";
			["Talpa Di Fero"] = "rbxassetid://121724449756841";
			["Bambini Crostini"] = "rbxassetid://123721597749487";
			["Avocadini Guffo"] = "rbxassetid://111841242578177";
			["Blueberrinni Octopusini"] = "rbxassetid://82979087510664";
			["Pipi Potato"] = "rbxassetid://91128761427401";
			["Gorillo Watermelondrillo"] = "rbxassetid://100641105570678";
			["Lerulerulerule"] = "rbxassetid://136504040993488";
			["Tigroligre Frutonni"] = "rbxassetid://89099746058734";
			["Tralalita Tralala"] = "rbxassetid://80037718938630";
			["Pakrahmatmamat"] = "rbxassetid://137571463530872";
			["Torrtuginni Dragonfrutini"] = "rbxassetid://125986845082543";
			["Espresso Signora"] = "rbxassetid://129441695494854";
			["Chicleteira Bicicleteira"] = "rbxassetid://90818946859682";
			["Pakrahmatmatina"] = "rbxassetid://129228817245064";
			["Tric Trac Barabum"] = "rbxassetid://140589228080373";
			["Lionel Cactuseli"] = "rbxassetid://76934240495703";
			["Ganganzelli Trulala"] = "rbxassetid://128303435403137";
			["Swag Soda"] = "rbxassetid://109976495035582";
			["Chillin Chili"] = "rbxassetid://96537934693313";
			["La Grande Combinasion"] = "rbxassetid://70964524332694";
			["Tralaledon"] = "rbxassetid://135869749959479";
			["Triplito Tralaleritos"] = "rbxassetid://70776293439295";
			["Chicleteirina Bicicleteirina"] = "rbxassetid://115376092057343";
			["Banana Dancana"] = "rbxassetid://102203509593380";
			["Illuminato Triangolo"] = "rbxassetid://112238318744692";
			["Nyannini Cattalini"] = "rbxassetid://115117030752534";
			["Smurfo Gatto"] = "rbxassetid://121816151043020";
			["Bananini Kittini"] = "rbxassetid://89615465540824";
			["Noo My Examen"] = "rbxassetid://130766865208869";
			["Yess My Examen"] = "rbxassetid://122297038158718";
			["Cachorrito Melonito"] = "rbxassetid://123533293797717";
			["W Or L"] = "rbxassetid://105200598240399";
			["1x1x1x1"] = "rbxassetid://140464622789332";
			["Meowl"] = "rbxassetid://91408337828896";
			["Wristini Rizzini"] = "rbxassetid://135217898791467";
			["Chestini Tralalero"] = "rbxassetid://130284147049083";
			["Skrrtini Driftini"] = "rbxassetid://118108480794631";
			["Pakrahmatmatina Valentina"] = "rbxassetid://111323938914918";
			["Love Love Love Sahur"] = "rbxassetid://127592758963014";
			["Noo My Heart"] = "rbxassetid://76900411218211";
			["Teddino Rosino"] = "rbxassetid://77536899158846";
			["La Cucaracha"] = "rbxassetid://106048276847055";
			["Ranocchio Del Tesoro"] = "rbxassetid://121869958551519";
			["Pinguino Pentadagoro"] = "rbxassetid://70388055002373";
		};
		["Galaxy "] = {
			["Agarrini La Pallini"] = "rbxassetid://128378705916722";
			["Ballerina Cappuccina"] = "rbxassetid://134034371499336";
			["Ballerino Lololo"] = "rbxassetid://132302264095505";
			["Bobrito Bandito"] = "rbxassetid://99771587318462";
			["Bananita Dolphinita"] = "rbxassetid://92630399296637";
			["Boneca Ambalabu"] = "rbxassetid://85122778248386";
			["Bombardiro Crocodilo"] = "rbxassetid://74298079926849";
			["Bombombini Gusini"] = "rbxassetid://129357336412184";
			["Brri Brri Bicus Dicus"] = "rbxassetid://98028561647114";
			["Brr Brr Patapim"] = "rbxassetid://90237088671839";
			["Burbaloni Luliloli"] = "rbxassetid://106194109829346";
			["Cacto Hipopotamo"] = "rbxassetid://107401741003058";
			["Cappuccino Assassino"] = "rbxassetid://93668885631115";
			["Cavallo Virtuoso"] = "rbxassetid://82086927081168";
			["Chef Crabracadabra"] = "rbxassetid://114628250825094";
			["Chimpanzini Bananini"] = "rbxassetid://123146307601711";
			["Cocofanto Elefanto"] = "rbxassetid://93405263788977";
			["Dragon Cannelloni"] = "rbxassetid://104630154888418";
			["Esok Sekolah"] = "rbxassetid://78955347323411";
			["Fluri Flura"] = "rbxassetid://102647172658238";
			["Frigo Camelo"] = "rbxassetid://73209742505653";
			["Garamararam"] = "rbxassetid://138653994817723";
			["Gangster Footera"] = "rbxassetid://86364568804361";
			["Girafa Celeste"] = "rbxassetid://126990812019215";
			["Glorbo Fruttodrillo"] = "rbxassetid://121643028371678";
			["Job Job Job Sahur"] = "rbxassetid://117648457831715";
			["Karkerkar Kurkur"] = "rbxassetid://132670250922613";
			["La Vacca Saturno Saturnita"] = "rbxassetid://114082638096450";
			["Lirili Larila"] = "rbxassetid://111427589326646";
			["Los Tralaleritos"] = "rbxassetid://86541918607215";
			["Madudung"] = "rbxassetid://108405806282701";
			["Matteo"] = "rbxassetid://133797275312306";
			["Odin Din Din Dun"] = "rbxassetid://87498067668237";
			["Orangutini Ananassini"] = "rbxassetid://107318868157641";
			["Orcalero Orcala"] = "rbxassetid://96573089223267";
			["Pandaccini Bananini"] = "rbxassetid://94886169608162";
			["Pipi Kiwi"] = "rbxassetid://104459100476098";
			["Pot Hotspot"] = "rbxassetid://72026915706689";
			["Rhino Toasterino"] = "rbxassetid://131487787306113";
			["Six Seven"] = "rbxassetid://138059744390546";
			["Strawberrelli Flamingelli"] = "rbxassetid://130804190044995";
			["Strawberry Elephant"] = "rbxassetid://129097789425146";
			["Svinina Bombardino"] = "rbxassetid://105994600590429";
			["Ta Ta Ta Ta Sahur"] = "rbxassetid://133381654191148";
			["Tralalero Tralala"] = "rbxassetid://82276949394066";
			["Trippi Troppi"] = "rbxassetid://121953094225463";
			["Trippi Troppi Troppa Trippa"] = "rbxassetid://103898338322137";
			["Trulimero Trulicina"] = "rbxassetid://77291493683032";
			["Tung Sahur"] = "rbxassetid://94028130438225";
			["Zibra Zubra Zibralini"] = "rbxassetid://88520374536881";
			["Tim Cheese"] = "rbxassetid://76142386070619";
			["Talpa Di Fero"] = "rbxassetid://80192306870081";
			["Bambini Crostini"] = "rbxassetid://113580180477741";
			["Avocadini Guffo"] = "rbxassetid://76476304503599";
			["Blueberrinni Octopusini"] = "rbxassetid://131251746019262";
			["Pipi Potato"] = "rbxassetid://110858857462592";
			["Gorillo Watermelondrillo"] = "rbxassetid://82650012019061";
			["Lerulerulerule"] = "rbxassetid://98265542376356";
			["Tigroligre Frutonni"] = "rbxassetid://137154552284710";
			["Tralalita Tralala"] = "rbxassetid://129804294380198";
			["Pakrahmatmamat"] = "rbxassetid://121558067277108";
			["Torrtuginni Dragonfrutini"] = "rbxassetid://74620431771027";
			["Espresso Signora"] = "rbxassetid://74620431771027";
			["Chicleteira Bicicleteira"] = "rbxassetid://90868038797493";
			["Pakrahmatmatina"] = "rbxassetid://129051031204529";
			["Tric Trac Barabum"] = "rbxassetid://70676539005522";
			["Lionel Cactuseli"] = "rbxassetid://111183942856173";
			["Ganganzelli Trulala"] = "rbxassetid://84043728552939";
			["Swag Soda"] = "rbxassetid://107903894749478";
			["Chillin Chili"] = "rbxassetid://126122563180883";
			["La Grande Combinasion"] = "rbxassetid://98127595179706";
			["Tralaledon"] = "rbxassetid://90428137242234";
			["Triplito Tralaleritos"] = "rbxassetid://92393458575735";
			["Chicleteirina Bicicleteirina"] = "rbxassetid://90266990338053";
			["Banana Dancana"] = "rbxassetid://90334680759276";
			["Illuminato Triangolo"] = "rbxassetid://122184866994523";
			["Nyannini Cattalini"] = "rbxassetid://94402579211549";
			["Smurfo Gatto"] = "rbxassetid://103427854753780";
			["Bananini Kittini"] = "rbxassetid://80263267586387";
			["Noo My Examen"] = "rbxassetid://87188458142564";
			["Yess My Examen"] = "rbxassetid://98615012905192";
			["Cachorrito Melonito"] = "rbxassetid://80053169164892";
			["W Or L"] = "rbxassetid://97586240915152";
			["1x1x1x1"] = "rbxassetid://120245357506745";
			["Meowl"] = "rbxassetid://124910856827575";
			["Wristini Rizzini"] = "rbxassetid://139360265250250";
			["Chestini Tralalero"] = "rbxassetid://115224499415442";
			["Skrrtini Driftini"] = "rbxassetid://118108480794631";
			["Pakrahmatmatina Valentina"] = "rbxassetid://124959137040108";
			["Love Love Love Sahur"] = "rbxassetid://73765908374165";
			["Noo My Heart"] = "rbxassetid://110069495239896";
			["Teddino Rosino"] = "rbxassetid://91348346837013";
			["La Cucaracha"] = "rbxassetid://132274049293453";
			["Ranocchio Del Tesoro"] = "rbxassetid://115630196549600";
			["Pinguino Pentadagoro"] = "rbxassetid://108206945058785";
		};
		["Hacker "] = {
			["Agarrini La Pallini"] = "rbxassetid://70725544731337";
			["Avocadini Guffo"] = "rbxassetid://119025359436194";
			["Ballerina Cappuccina"] = "rbxassetid://112230596615379";
			["Ballerino Lololo"] = "rbxassetid://71607350642157";
			["Banana Dancana"] = "rbxassetid://113792111031011";
			["Blueberrinni Octopusini"] = "rbxassetid://97913441374394";
			["Bobrito Bandito"] = "rbxassetid://100990518588870";
			["Bambini Crostini"] = "rbxassetid://111397876403176";
			["Bananini Kittini"] = "rbxassetid://109127078815899";
			["Bananita Dolphinita"] = "rbxassetid://75521919163452";
			["Boneca Ambalabu"] = "rbxassetid://89635324394727";
			["Bombardiro Crocodilo"] = "rbxassetid://98823482546838";
			["Bombombini Gusini"] = "rbxassetid://91616675321672";
			["Brri Brri Bicus Dicus"] = "rbxassetid://113820739798923";
			["Brr Brr Patapim"] = "rbxassetid://130163465489131";
			["Burbaloni Luliloli"] = "rbxassetid://130245787227894";
			["Cachorrito Melonito"] = "rbxassetid://79191433090027";
			["Cacto Hipopotamo"] = "rbxassetid://91865780803976";
			["Cappuccino Assassino"] = "rbxassetid://135538975156422";
			["Cavallo Virtuoso"] = "rbxassetid://121515343898090";
			["Chef Crabracadabra"] = "rbxassetid://126330283802539";
			["Chicleteira Bicicleteira"] = "rbxassetid://93940870121242";
			["Chicleteirina Bicicleteirina"] = "rbxassetid://135895612533592";
			["Chimpanzini Bananini"] = "rbxassetid://92388149154802";
			["Chillin Chili"] = "rbxassetid://140258097992030";
			["Cocofanto Elefanto"] = "rbxassetid://73089323449630";
			["Dragon Cannelloni"] = "rbxassetid://121800499226534";
			["Esok Sekolah"] = "rbxassetid://85685929891561";
			["Espresso Signora"] = "rbxassetid://114512125039499";
			["Fluri Flura"] = "rbxassetid://97663051638003";
			["Frigo Camelo"] = "rbxassetid://119258951176781";
			["Garamararam"] = "rbxassetid://89605138908627";
			["Ganganzelli Trulala"] = "rbxassetid://124762598572064";
			["Gangster Footera"] = "rbxassetid://75474485285022";
			["Girafa Celeste"] = "rbxassetid://113802485069752";
			["Glorbo Fruttodrillo"] = "rbxassetid://129730271253523";
			["Gorillo Watermelondrillo"] = "rbxassetid://115670042024085";
			["Illuminato Triangolo"] = "rbxassetid://84695901959461";
			["Job Job Job Sahur"] = "rbxassetid://75103125617346";
			["Karkerkar Kurkur"] = "rbxassetid://96269546227933";
			["La Grande Combinasion"] = "rbxassetid://99860632678005";
			["La Vacca Saturno Saturnita"] = "rbxassetid://123610505225020";
			["Lerulerulerule"] = "rbxassetid://71770063131888";
			["Lionel Cactuseli"] = "rbxassetid://88846959473404";
			["Lirili Larila"] = "rbxassetid://121788194375782";
			["Los Tralaleritos"] = "rbxassetid://76316506230798";
			["Madudung"] = "rbxassetid://83158827259553";
			["Matteo"] = "rbxassetid://140088869661896";
			["Meowl"] = "rbxassetid://134303867532609";
			["Nyannini Cattalini"] = "rbxassetid://101641189747769";
			["Noo My Examen"] = "rbxassetid://76327413324096";
			["Odin Din Din Dun"] = "rbxassetid://96060263010297";
			["Orangutini Ananassini"] = "rbxassetid://73544836687411";
			["Orcalero Orcala"] = "rbxassetid://105144586250832";
			["Pakrahmatmama"]t = "rbxassetid://91763780815282";
			["Pakrahmatmatina"] = "rbxassetid://96967436611342";
			["Pandaccini Bananini"] = "rbxassetid://122592150806534";
			["Pipi Kiwi"] = "rbxassetid://139141374985134";
			["Pipi Potato"] = "rbxassetid://138592453457510";
			["Pot Hotspot"] = "rbxassetid://107309735218401";
			["Rhino Toasterino"] = "rbxassetid://122352482055354";
			["Six Seven"] = "rbxassetid://97853823971340";
			["Smurfo Gatto"] = "rbxassetid://132034469201096";
			["Strawberrelli Flamingelli"] = "rbxassetid://125543304308838";
			["Strawberry Elephant"] = "rbxassetid://107986662165979";
			["Svinina Bombardino"] = "rbxassetid://114789719885694";
			["Swag Soda"] = "rbxassetid://116955660065005";
			["Ta Ta Ta Ta Sahur"] = "rbxassetid://122201150102037";
			["Talpa Di Fero"] = "rbxassetid://132747663121149";
			["Tigroligre Frutonni"] = "rbxassetid://84910613416406";
			["Tim Cheese"] = "rbxassetid://93517484834080";
			["Torrtuginni Dragonfrutini"] = "rbxassetid://106126055680074";
			["Tralalita Tralala"] = "rbxassetid://71286973887848";
			["Tralalero Tralala"] = "rbxassetid://133132175122586";
			["Tralaledon"] = "rbxassetid://103171452178219";
			["Tric Trac Barabum"] = "rbxassetid://130019643831697";
			["Triplito Tralaleritos"] = "rbxassetid://80608777068964";
			["Trippi Troppi"] = "rbxassetid://73012337253154";
			["Trippi Troppi Troppa Trippa"] = "rbxassetid://94637862762196";
			["Trulimero Trulicina"] = "rbxassetid://108887248280759";
			["Tung Sahur"] = "rbxassetid://101343378229514";
			["W Or L"] = "rbxassetid://78061409484613";
			["Yess My Examen"] = "rbxassetid://119769948486037";
			["Zibra Zubra Zibralini"] = "rbxassetid://116612138900697";
			["1x1x1x1"] = "rbxassetid://140104650271971";
			["Wristini Rizzini"] = "rbxassetid://135217898791467";
			["Chestini Tralalero"] = "rbxassetid://130284147049083";
			["Skrrtini Driftini"] = "rbxassetid://118108480794631";
			["Pakrahmatmatina Valentina"] = "rbxassetid://94004957678711";
			["Love Love Love Sahur"] = "rbxassetid://75042002173590";
			["Noo My Heart"] = "rbxassetid://119380797751144";
			["Teddino Rosino"] = "rbxassetid://104487095561216";
			["La Cucaracha"] = "rbxassetid://133625725205487";
			["Ranocchio Del Tesoro"] = "rbxassetid://129050041046711";
			["Pinguino Pentadagoro"] = "rbxassetid://121191841058444";
		};
		["Rainbow "] = tbl;
	})[v_2.Prefix]
	if var155 then
		(function(arg1, arg2, arg3) -- Line 912, Named "addVariant"
			--[[ Upvalues[4]:
				[1]: module_upvr (readonly)
				[2]: tbl_2_upvr (readonly)
				[3]: module_upvr_2 (readonly)
				[4]: formatCommas_upvr (readonly)
			]]
			-- KONSTANTERROR: [0] 1. Error Block 1 start (CF ANALYSIS FAILED)
			local ipairs_result1, ipairs_result2_2, ipairs_result3 = ipairs(module_upvr.VARIANTS)
			-- KONSTANTERROR: [0] 1. Error Block 1 end (CF ANALYSIS FAILED)
			-- KONSTANTERROR: [15] 11. Error Block 4 start (CF ANALYSIS FAILED)
			-- KONSTANTERROR: [15] 11. Error Block 4 end (CF ANALYSIS FAILED)
			-- KONSTANTERROR: [8] 7. Error Block 24 start (CF ANALYSIS FAILED)
			-- KONSTANTWARNING: Failed to evaluate expression, replaced with nil [15.9]
			-- KONSTANTWARNING: Failed to evaluate expression, replaced with nil [15.2147483650]
			if nil == arg1 then
				local _, _, _ = pairs(tbl_2_upvr)
				-- KONSTANTWARNING: GOTO [22] #16
			end
			-- KONSTANTERROR: [8] 7. Error Block 24 end (CF ANALYSIS FAILED)
		end)(v_2.Prefix, var155, v_2.CpsMultiplier)
	end
end
return module_upvr_2