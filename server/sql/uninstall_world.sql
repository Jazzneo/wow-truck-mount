-- Truck Mount uninstall: new characters no longer start with the truck buttons.
DELETE FROM `playercreateinfo_spell_custom` WHERE `Spell` IN (55531, 60424);
