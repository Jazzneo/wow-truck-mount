-- Truck Mount: give both truck buttons to every existing character.
-- Characters that get a button from this installer are remembered in `truck_mount_granted`,
-- so uninstalling removes only what the installer added (a crafted Mechano-Hog stays).
CREATE TABLE IF NOT EXISTS `truck_mount_granted` (
  `guid` INT UNSIGNED NOT NULL,
  `spell` INT UNSIGNED NOT NULL,
  PRIMARY KEY (`guid`, `spell`)
);
INSERT IGNORE INTO `truck_mount_granted` (`guid`, `spell`)
SELECT c.`guid`, 55531 FROM `characters` c
LEFT JOIN `character_spell` s ON s.`guid` = c.`guid` AND s.`spell` = 55531 WHERE s.`guid` IS NULL;
INSERT IGNORE INTO `truck_mount_granted` (`guid`, `spell`)
SELECT c.`guid`, 60424 FROM `characters` c
LEFT JOIN `character_spell` s ON s.`guid` = c.`guid` AND s.`spell` = 60424 WHERE s.`guid` IS NULL;
INSERT IGNORE INTO `character_spell` (`guid`, `spell`, `specMask`)
SELECT `guid`, 55531, 255 FROM `characters`;
INSERT IGNORE INTO `character_spell` (`guid`, `spell`, `specMask`)
SELECT `guid`, 60424, 255 FROM `characters`;
