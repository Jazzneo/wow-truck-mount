-- Truck Mount: new characters start with both truck buttons.
-- Needs PlayerStart.CustomSpells = 1 in worldserver.conf (the installer turns it on).
--   55531 = Truck with Lights      (Mechano-Hog spell, changed by the client patch)
--   60424 = Truck with No Lights   (Mekgineers Chopper spell, changed by the client patch)
DELETE FROM `playercreateinfo_spell_custom` WHERE `Spell` IN (55531, 60424);
INSERT INTO `playercreateinfo_spell_custom` (`racemask`, `classmask`, `Spell`, `Note`) VALUES
(0, 0, 55531, 'Truck Mount: Truck with Lights'),
(0, 0, 60424, 'Truck Mount: Truck with No Lights');
