-- Author: Noah Pragin
-- Date: 2025-04-29
-- Description: This file contains the DML queries for the pokemon database.
-- Note: @ is used to indicate a placeholder variable.
--       Camel case is used to avoid confusion with table names and attributes.
-- Note: None of these will be used. The PL file contains all queries as stored procedures.

-------------------------------|
-- Query to create a new party |
-------------------------------|
INSERT INTO parties VALUES ();

---------------------------|
-- Query to delete a party |
-- Given: @partyId         |
---------------------------|

-- Delete entries from parties_has_customized_pokemon for this party
DELETE FROM parties_has_customized_pokemon WHERE parties_id = @partyId;

-- Delete the party
DELETE FROM parties WHERE parties_id = @partyId;

-- Delete the moves for the customized pokemon if any are now unused
DELETE FROM customized_pokemon_has_moves 
WHERE customized_pokemon_id NOT IN (
    SELECT customized_pokemon_id 
    FROM parties_has_customized_pokemon
);

-- Delete the customized pokemon if any are now unused
DELETE FROM customized_pokemon 
WHERE customized_pokemon_id NOT IN (
    SELECT customized_pokemon_id 
    FROM parties_has_customized_pokemon
);

------------------------------------------------------------------|
-- Query to add a brand new pokemon to a party                    |
-- Given: @partyId, @pokemonId                                    |
-- Note: When a pokemon is added to a party it is given the       |
--       first available ability and nature and no moves or items |
------------------------------------------------------------------|

-- Get the ability ID for the new pokemon
SET @pokemon_ability = (
    SELECT a.abilities_id 
    FROM abilities a 
    JOIN pokemon_has_abilities pha ON a.abilities_id = pha.abilities_id 
    WHERE pha.pokemon_id = @pokemonId
    LIMIT 1
);

-- Identify if the default configuration for this pokemon already exists
SET @existing_pokemon_id = (
    SELECT cp.customized_pokemon_id 
    FROM customized_pokemon cp 
    LEFT JOIN customized_pokemon_has_moves cphm ON cp.customized_pokemon_id = cphm.customized_pokemon_id 
    WHERE
        cp.pokemon_id = @pokemonId AND
        cp.items_id IS NULL AND
        cp.abilities_id = @pokemon_ability AND
        cp.natures_id = 1 AND
        cphm.customized_pokemon_id IS NULL
    LIMIT 1
);

-- Insert new Pokémon if the default configuration doesn't already exist
-- Must use SELECT instead of VALUES to use WHERE
INSERT INTO customized_pokemon (pokemon_id, items_id, abilities_id, natures_id)
SELECT @pokemonId, NULL, @pokemon_ability, 1
WHERE @existing_pokemon_id IS NULL;

-- Update variable with new ID if we inserted
SET @new_pokemon_id = LAST_INSERT_ID();

-- Use COALESCE to select either existing or new ID
SET @pokemon_id_to_use = COALESCE(@existing_pokemon_id, @new_pokemon_id);

-- Insert into party
INSERT INTO parties_has_customized_pokemon (parties_id, customized_pokemon_id)
VALUES (@partyId, @pokemon_id_to_use);

------------------------------------------|
-- Query to remove a pokemon from a party |
-- Given: @partyId, @customizedPokemonId  |
------------------------------------------|

-- Delete the pokemon from the party
DELETE FROM parties_has_customized_pokemon 
WHERE parties_id = @partyId AND customized_pokemon_id = @customizedPokemonId;

-- Delete the moves for the pokemon if it is now unused
DELETE FROM customized_pokemon_has_moves 
WHERE customized_pokemon_id NOT IN (
    SELECT customized_pokemon_id 
    FROM parties_has_customized_pokemon
);

-- Delete the customized pokemon if it is now unused
DELETE FROM customized_pokemon 
WHERE customized_pokemon_id NOT IN (
    SELECT customized_pokemon_id 
    FROM parties_has_customized_pokemon
);

----------------------------------------------------------------------|
-- Query to update an existing pokemon's ability, item, and/or nature |
-- Given: @partyId, @customizedPokemonId, @itemsId, @natureId,        |
--        @abilityId                                                  |
----------------------------------------------------------------------|

-- Check if the old pokemon configuration is in another party
SET @old_configuration_in_use = (
    SELECT COUNT(*) > 0
    FROM parties_has_customized_pokemon
    WHERE customized_pokemon_id = @customizedPokemonId AND parties_id != @partyId
);

-- Check if the new pokemon configuration already exists
SET @existing_pokemon_id = (
    SELECT DISTINCT cp.customized_pokemon_id
    FROM customized_pokemon cp 
    JOIN customized_pokemon_has_moves cphm ON cp.customized_pokemon_id = cphm.customized_pokemon_id
    WHERE
        cp.pokemon_id = (SELECT pokemon_id FROM customized_pokemon WHERE customized_pokemon_id = @customizedPokemonId) AND
        cp.items_id <=> @itemsId AND
        cp.abilities_id = @abilityId AND
        cp.natures_id = @natureId AND
        NOT EXISTS (
            SELECT moves_id 
            FROM customized_pokemon_has_moves 
            WHERE customized_pokemon_id = @customizedPokemonId
            EXCEPT
            SELECT moves_id 
            FROM customized_pokemon_has_moves 
            WHERE customized_pokemon_id = cp.customized_pokemon_id
        ) AND
        NOT EXISTS (
            SELECT moves_id 
            FROM customized_pokemon_has_moves 
            WHERE customized_pokemon_id = cp.customized_pokemon_id
            EXCEPT
            SELECT moves_id 
            FROM customized_pokemon_has_moves 
            WHERE customized_pokemon_id = @customizedPokemonId
        )
);

-- Identify if we need to create a new pokemon, can update the existing configuration, or one already exists
SET @needs_new_pokemon = (@existing_pokemon_id IS NULL AND @old_configuration_in_use = 1);
SET @can_update_pokemon = (@existing_pokemon_id IS NULL AND @old_configuration_in_use = 0);

-- Create new pokemon if needed
INSERT INTO customized_pokemon (pokemon_id, items_id, abilities_id, natures_id)
SELECT (SELECT pokemon_id FROM customized_pokemon WHERE customized_pokemon_id = @customizedPokemonId), @itemsId, @abilityId, @natureId
WHERE @needs_new_pokemon = 1;

-- Get the ID of the newly inserted pokemon
SET @new_pokemon_id = IF(@needs_new_pokemon = 1, LAST_INSERT_ID(), NULL);

-- Insert moves for the new pokemon
INSERT INTO customized_pokemon_has_moves (customized_pokemon_id, moves_id)
SELECT @new_pokemon_id, moves_id
FROM customized_pokemon_has_moves
WHERE customized_pokemon_id = @customizedPokemonId
AND @new_pokemon_id IS NOT NULL;

-- Update existing configuration if needed
UPDATE customized_pokemon
SET pokemon_id = (SELECT pokemon_id FROM customized_pokemon WHERE customized_pokemon_id = @customizedPokemonId),
    items_id = @itemsId,
    abilities_id = @abilityId,
    natures_id = @natureId
WHERE customized_pokemon_id = @customizedPokemonId
AND @can_update_pokemon = 1;

-- Determine which ID to use to update the party
SET @pokemon_id_to_use = CASE
    WHEN @existing_pokemon_id IS NOT NULL THEN @existing_pokemon_id
    WHEN @needs_new_pokemon = 1 THEN @new_pokemon_id
    ELSE @customizedPokemonId
END;

-- Update the party to use the new pokemon
UPDATE parties_has_customized_pokemon
SET customized_pokemon_id = @pokemon_id_to_use
WHERE parties_id = @partyId AND customized_pokemon_id = @customizedPokemonId;

-- Delete the moves for any pokemon not in any party
DELETE FROM customized_pokemon_has_moves 
WHERE customized_pokemon_id NOT IN (
    SELECT customized_pokemon_id 
    FROM parties_has_customized_pokemon
);

-- Clean up unused pokemon
DELETE FROM customized_pokemon 
WHERE customized_pokemon_id NOT IN (
    SELECT customized_pokemon_id 
    FROM parties_has_customized_pokemon
);

-----------------------------------------|
-- Query to delete a move from a pokemon |
-- Given: @partyId, @customizedPokemonId,|
--        @moveId                        |
-----------------------------------------|

-- Check if the old pokemon configuration is in another party
SET @old_configuration_in_use = (
    SELECT COUNT(*) > 0
    FROM parties_has_customized_pokemon
    WHERE customized_pokemon_id = @customizedPokemonId AND parties_id != @partyId
);

-- Check if the new pokemon configuration already exists
SET @existing_pokemon_id = (
    SELECT DISTINCT cp.customized_pokemon_id
    FROM customized_pokemon cp 
    JOIN customized_pokemon_has_moves cphm ON cp.customized_pokemon_id = cphm.customized_pokemon_id
    WHERE
        cp.pokemon_id = (SELECT pokemon_id FROM customized_pokemon WHERE customized_pokemon_id = @customizedPokemonId) AND
        cp.items_id <=> (SELECT items_id FROM customized_pokemon WHERE customized_pokemon_id = @customizedPokemonId) AND
        cp.abilities_id = (SELECT abilities_id FROM customized_pokemon WHERE customized_pokemon_id = @customizedPokemonId) AND
        cp.natures_id = (SELECT natures_id FROM customized_pokemon WHERE customized_pokemon_id = @customizedPokemonId) AND
        @moveId = (
            SELECT moves_id 
            FROM customized_pokemon_has_moves 
            WHERE customized_pokemon_id = @customizedPokemonId
            EXCEPT
            SELECT moves_id 
            FROM customized_pokemon_has_moves 
            WHERE customized_pokemon_id = cp.customized_pokemon_id
        ) AND
        NOT EXISTS (
            SELECT moves_id 
            FROM customized_pokemon_has_moves 
            WHERE customized_pokemon_id = cp.customized_pokemon_id
            EXCEPT
            SELECT moves_id 
            FROM customized_pokemon_has_moves 
            WHERE customized_pokemon_id = @customizedPokemonId
        )
);

-- Identify if we need to create a new pokemon, can update the existing configuration, or one already exists
SET @needs_new_pokemon = (@existing_pokemon_id IS NULL AND @old_configuration_in_use = 1);
SET @can_update_pokemon = (@existing_pokemon_id IS NULL AND @old_configuration_in_use = 0);

-- Create new pokemon if needed
INSERT INTO customized_pokemon (pokemon_id, items_id, abilities_id, natures_id)
SELECT (SELECT pokemon_id FROM customized_pokemon WHERE customized_pokemon_id = @customizedPokemonId),
       (SELECT items_id FROM customized_pokemon WHERE customized_pokemon_id = @customizedPokemonId),
       (SELECT abilities_id FROM customized_pokemon WHERE customized_pokemon_id = @customizedPokemonId),
       (SELECT natures_id FROM customized_pokemon WHERE customized_pokemon_id = @customizedPokemonId)
WHERE @needs_new_pokemon = 1;

-- Get the ID of the newly inserted pokemon
SET @new_pokemon_id = IF(@needs_new_pokemon = 1, LAST_INSERT_ID(), NULL);

-- Insert moves for the new pokemon, except the one we're deleting
INSERT INTO customized_pokemon_has_moves (customized_pokemon_id, moves_id)
SELECT @new_pokemon_id, moves_id
FROM customized_pokemon_has_moves
WHERE customized_pokemon_id = @customizedPokemonId
AND moves_id != @moveId
AND @new_pokemon_id IS NOT NULL;

-- Delete move from existing configuration if needed
DELETE FROM customized_pokemon_has_moves
WHERE customized_pokemon_id = @customizedPokemonId
AND moves_id = @moveId
AND @can_update_pokemon = 1;

-- Determine which ID to use to update the party
SET @pokemon_id_to_use = CASE
    WHEN @existing_pokemon_id IS NOT NULL THEN @existing_pokemon_id
    WHEN @needs_new_pokemon = 1 THEN @new_pokemon_id
    ELSE @customizedPokemonId
END;

-- Update the party to use the new pokemon
UPDATE parties_has_customized_pokemon
SET customized_pokemon_id = @pokemon_id_to_use
WHERE parties_id = @partyId AND customized_pokemon_id = @customizedPokemonId;

-- Delete the moves for any pokemon not in any party
DELETE FROM customized_pokemon_has_moves 
WHERE customized_pokemon_id NOT IN (
    SELECT customized_pokemon_id 
    FROM parties_has_customized_pokemon
);

-- Clean up unused pokemon
DELETE FROM customized_pokemon 
WHERE customized_pokemon_id NOT IN (
    SELECT customized_pokemon_id 
    FROM parties_has_customized_pokemon
);

---------------------------------------|
-- Query to add a move to a pokemon    |
-- Given: @partyId,                    |
--        @customizedPokemonId, @moveId|
---------------------------------------|

-- Check if the old pokemon configuration is in another party
SET @old_configuration_in_use = (
    SELECT COUNT(*) > 0
    FROM parties_has_customized_pokemon
    WHERE customized_pokemon_id = @customizedPokemonId AND parties_id != @partyId
);

-- Check if the new pokemon configuration already exists
SET @existing_pokemon_id = (
    SELECT DISTINCT cp.customized_pokemon_id
    FROM customized_pokemon cp 
    JOIN customized_pokemon_has_moves cphm ON cp.customized_pokemon_id = cphm.customized_pokemon_id
    WHERE
        cp.pokemon_id = (SELECT pokemon_id FROM customized_pokemon WHERE customized_pokemon_id = @customizedPokemonId) AND
        cp.items_id <=> (SELECT items_id FROM customized_pokemon WHERE customized_pokemon_id = @customizedPokemonId) AND
        cp.abilities_id = (SELECT abilities_id FROM customized_pokemon WHERE customized_pokemon_id = @customizedPokemonId) AND
        cp.natures_id = (SELECT natures_id FROM customized_pokemon WHERE customized_pokemon_id = @customizedPokemonId) AND
        NOT EXISTS (
            SELECT moves_id 
            FROM customized_pokemon_has_moves 
            WHERE customized_pokemon_id = @customizedPokemonId
            EXCEPT
            SELECT moves_id 
            FROM customized_pokemon_has_moves 
            WHERE customized_pokemon_id = cp.customized_pokemon_id
        ) AND
        @moveId = (
            SELECT moves_id 
            FROM customized_pokemon_has_moves 
            WHERE customized_pokemon_id = cp.customized_pokemon_id
            EXCEPT
            SELECT moves_id 
            FROM customized_pokemon_has_moves 
            WHERE customized_pokemon_id = @customizedPokemonId
        )
);

-- Identify if we need to create a new pokemon, can update the existing configuration, or one already exists
SET @needs_new_pokemon = (@existing_pokemon_id IS NULL AND @old_configuration_in_use = 1);
SET @can_update_pokemon = (@existing_pokemon_id IS NULL AND @old_configuration_in_use = 0);

-- Create new pokemon if needed
INSERT INTO customized_pokemon (pokemon_id, items_id, abilities_id, natures_id)
SELECT (SELECT pokemon_id FROM customized_pokemon WHERE customized_pokemon_id = @customizedPokemonId),
       (SELECT items_id FROM customized_pokemon WHERE customized_pokemon_id = @customizedPokemonId),
       (SELECT abilities_id FROM customized_pokemon WHERE customized_pokemon_id = @customizedPokemonId),
       (SELECT natures_id FROM customized_pokemon WHERE customized_pokemon_id = @customizedPokemonId)
WHERE @needs_new_pokemon = 1;

-- Get the ID of the newly inserted pokemon
SET @new_pokemon_id = IF(@needs_new_pokemon = 1, LAST_INSERT_ID(), NULL);

-- Insert moves from the old pokemon configuration into the new pokemon
INSERT INTO customized_pokemon_has_moves (customized_pokemon_id, moves_id)
SELECT @new_pokemon_id, moves_id
FROM customized_pokemon_has_moves
WHERE customized_pokemon_id = @customizedPokemonId
AND @new_pokemon_id IS NOT NULL;

-- Insert the new move into the new pokemon
INSERT INTO customized_pokemon_has_moves (customized_pokemon_id, moves_id)
SELECT @new_pokemon_id, @moveId
WHERE @new_pokemon_id IS NOT NULL;

-- Add move to the existing configuration if needed
INSERT INTO customized_pokemon_has_moves (customized_pokemon_id, moves_id)
SELECT @customizedPokemonId, @moveId
WHERE @can_update_pokemon = 1;

-- Determine which ID to use to update the party
SET @pokemon_id_to_use = CASE
    WHEN @existing_pokemon_id IS NOT NULL THEN @existing_pokemon_id
    WHEN @needs_new_pokemon = 1 THEN @new_pokemon_id
    ELSE @customizedPokemonId
END;

-- Update the party to use the new pokemon
UPDATE parties_has_customized_pokemon
SET customized_pokemon_id = @pokemon_id_to_use
WHERE parties_id = @partyId AND customized_pokemon_id = @customizedPokemonId;

-- Delete the moves for any pokemon not in any party
DELETE FROM customized_pokemon_has_moves 
WHERE customized_pokemon_id NOT IN (
    SELECT customized_pokemon_id 
    FROM parties_has_customized_pokemon
);

-- Clean up unused pokemon
DELETE FROM customized_pokemon 
WHERE customized_pokemon_id NOT IN (
    SELECT customized_pokemon_id 
    FROM parties_has_customized_pokemon
);