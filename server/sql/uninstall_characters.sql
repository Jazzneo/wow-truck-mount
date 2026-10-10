-- Truck Mount uninstall: remove only the truck buttons this installer gave out.
CREATE TABLE IF NOT EXISTS `truck_mount_granted` (
  `guid` INT UNSIGNED NOT NULL,
  `spell` INT UNSIGNED NOT NULL,
  PRIMARY KEY (`guid`, `spell`)
);
DELETE FROM `character_spell` WHERE (`guid`, `spell`) IN (SELECT `guid`, `spell` FROM `truck_mount_granted`);
DROP TABLE `truck_mount_granted`;
