-- Author: Noah Pragin
-- Date: 2025-04-29
-- Description: This file contains the PL queries for interacting with the pokemon database.
-- AI Notice: AI tools were used to create this file.

-- MANIPULATION PROCEDURES

DELIMITER //
CREATE OR REPLACE PROCEDURE cleanUnusedCustomizedPokemon()
BEGIN
    -- Delete moves of unused customized pokemon
    DELETE FROM customized_pokemon_has_moves 
    WHERE customized_pokemon_id NOT IN (
        SELECT customized_pokemon_id 
        FROM parties_has_customized_pokemon
    );

    -- Delete unused customized pokemon
    DELETE FROM customized_pokemon 
    WHERE customized_pokemon_id NOT IN (
        SELECT customized_pokemon_id 
        FROM parties_has_customized_pokemon
    );
END//

CREATE OR REPLACE PROCEDURE createParty()
BEGIN
    INSERT INTO parties VALUES ();
END//

CREATE OR REPLACE PROCEDURE deleteParty(IN partyId INT)
BEGIN
    -- Delete entries from parties_has_customized_pokemon for this party
    DELETE FROM parties_has_customized_pokemon WHERE parties_id = partyId;

    -- Delete the party
    DELETE FROM parties WHERE parties_id = partyId;

    CALL cleanUnusedCustomizedPokemon();
END//

-- Note: When a pokemon is added to a party it is given the first available ability and nature and no moves or items |
CREATE OR REPLACE PROCEDURE addPokemonToParty(IN partyId INT, IN pokemonId INT)
BEGIN
    -- Get the ability ID for the new pokemon
    SET @pokemon_ability = (
        SELECT a.abilities_id 
        FROM abilities a 
        JOIN pokemon_has_abilities pha ON a.abilities_id = pha.abilities_id 
        WHERE pha.pokemon_id = pokemonId
        LIMIT 1
    );

    -- Identify if the default configuration for this pokemon already exists
    SET @existing_pokemon_id = (
        SELECT cp.customized_pokemon_id 
        FROM customized_pokemon cp 
        LEFT JOIN customized_pokemon_has_moves cphm ON cp.customized_pokemon_id = cphm.customized_pokemon_id 
        WHERE
            cp.pokemon_id = pokemonId AND
            cp.items_id IS NULL AND
            cp.abilities_id = @pokemon_ability AND
            cp.natures_id = 1 AND
            cphm.customized_pokemon_id IS NULL
        LIMIT 1
    );

    -- Insert new Pokémon if the default configuration doesn't already exist
    -- Must use SELECT instead of VALUES to use WHERE
    INSERT INTO customized_pokemon (pokemon_id, items_id, abilities_id, natures_id)
    SELECT pokemonId, NULL, @pokemon_ability, 1
    WHERE @existing_pokemon_id IS NULL;

    -- Update variable with new ID if we inserted
    SET @new_pokemon_id = LAST_INSERT_ID();

    -- Use COALESCE to select either existing or new ID
    SET @pokemon_id_to_use = COALESCE(@existing_pokemon_id, @new_pokemon_id);

    -- Insert into party
    INSERT INTO parties_has_customized_pokemon (parties_id, customized_pokemon_id)
    VALUES (partyId, @pokemon_id_to_use);
END//

CREATE OR REPLACE PROCEDURE removePokemonFromParty(IN partyId INT, IN customizedPokemonId INT)
BEGIN
    -- Delete the pokemon from the party
    DELETE FROM parties_has_customized_pokemon 
    WHERE parties_id = partyId AND customized_pokemon_id = customizedPokemonId;

    CALL cleanUnusedCustomizedPokemon();
END//

-- Note: This is only used to update non-move pokemon attributes. Pass in the current values for attributes you do not want to update.
CREATE OR REPLACE PROCEDURE updatePokemon(IN partyId INT, IN customizedPokemonId INT, IN abilityId INT, IN natureId INT, IN itemsId INT)
BEGIN
    -- Check if the old pokemon configuration is in another party
    SET @old_configuration_in_use = (
        SELECT COUNT(*) > 0
        FROM parties_has_customized_pokemon
        WHERE customized_pokemon_id = customizedPokemonId AND parties_id != partyId
    );

    -- Check if the new pokemon configuration already exists
    SET @existing_pokemon_id = (
        SELECT DISTINCT cp.customized_pokemon_id
        FROM customized_pokemon cp 
        JOIN customized_pokemon_has_moves cphm ON cp.customized_pokemon_id = cphm.customized_pokemon_id
        WHERE
            cp.pokemon_id = (SELECT pokemon_id FROM customized_pokemon WHERE customized_pokemon_id = customizedPokemonId) AND
            cp.items_id <=> itemsId AND
            cp.abilities_id = abilityId AND
            cp.natures_id = natureId AND
            NOT EXISTS (
                SELECT moves_id 
                FROM customized_pokemon_has_moves 
                WHERE customized_pokemon_id = customizedPokemonId
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
                WHERE customized_pokemon_id = customizedPokemonId
            )
    );

    -- Identify if we need to create a new pokemon, can update the existing configuration, or one already exists
    SET @needs_new_pokemon = (@existing_pokemon_id IS NULL AND @old_configuration_in_use = 1);
    SET @can_update_pokemon = (@existing_pokemon_id IS NULL AND @old_configuration_in_use = 0);

    -- Create new pokemon if needed
    INSERT INTO customized_pokemon (pokemon_id, items_id, abilities_id, natures_id)
    SELECT (SELECT pokemon_id FROM customized_pokemon WHERE customized_pokemon_id = customizedPokemonId), itemsId, abilityId, natureId
    WHERE @needs_new_pokemon = 1;

    -- Get the ID of the newly inserted pokemon
    SET @new_pokemon_id = IF(@needs_new_pokemon = 1, LAST_INSERT_ID(), NULL);

    -- Insert moves for the new pokemon
    INSERT INTO customized_pokemon_has_moves (customized_pokemon_id, moves_id)
    SELECT @new_pokemon_id, moves_id
    FROM customized_pokemon_has_moves
    WHERE customized_pokemon_id = customizedPokemonId
    AND @new_pokemon_id IS NOT NULL;

    -- Update existing configuration if needed
    UPDATE customized_pokemon
    SET pokemon_id = (SELECT pokemon_id FROM customized_pokemon WHERE customized_pokemon_id = customizedPokemonId),
        items_id = itemsId,
        abilities_id = abilityId,
        natures_id = natureId
    WHERE customized_pokemon_id = customizedPokemonId
    AND @can_update_pokemon = 1;

    -- Determine which ID to use to update the party
    SET @pokemon_id_to_use = CASE
        WHEN @existing_pokemon_id IS NOT NULL THEN @existing_pokemon_id
        WHEN @needs_new_pokemon = 1 THEN @new_pokemon_id
        ELSE customizedPokemonId
    END;

    -- Update the party to use the new pokemon
    UPDATE parties_has_customized_pokemon
    SET customized_pokemon_id = @pokemon_id_to_use
    WHERE parties_id = partyId AND customized_pokemon_id = customizedPokemonId;

    CALL cleanUnusedCustomizedPokemon();
END//

CREATE OR REPLACE PROCEDURE addMoveToPokemon(IN partyId INT, IN customizedPokemonId INT, IN moveId INT)
BEGIN
    -- Check if the old pokemon configuration is in another party
    SET @old_configuration_in_use = (
        SELECT COUNT(*) > 0
        FROM parties_has_customized_pokemon
        WHERE customized_pokemon_id = customizedPokemonId AND parties_id != partyId
    );

    -- Check if the new pokemon configuration already exists
    SET @existing_pokemon_id = (
        SELECT DISTINCT cp.customized_pokemon_id
        FROM customized_pokemon cp 
        JOIN customized_pokemon_has_moves cphm ON cp.customized_pokemon_id = cphm.customized_pokemon_id
        WHERE
            cp.pokemon_id = (SELECT pokemon_id FROM customized_pokemon WHERE customized_pokemon_id = customizedPokemonId) AND
            cp.items_id <=> (SELECT items_id FROM customized_pokemon WHERE customized_pokemon_id = customizedPokemonId) AND
            cp.abilities_id = (SELECT abilities_id FROM customized_pokemon WHERE customized_pokemon_id = customizedPokemonId) AND
            cp.natures_id = (SELECT natures_id FROM customized_pokemon WHERE customized_pokemon_id = customizedPokemonId) AND
            NOT EXISTS (
                SELECT moves_id 
                FROM customized_pokemon_has_moves 
                WHERE customized_pokemon_id = customizedPokemonId
                EXCEPT
                SELECT moves_id 
                FROM customized_pokemon_has_moves 
                WHERE customized_pokemon_id = cp.customized_pokemon_id
            ) AND
            moveId = (
                SELECT moves_id 
                FROM customized_pokemon_has_moves 
                WHERE customized_pokemon_id = cp.customized_pokemon_id
                EXCEPT
                SELECT moves_id 
                FROM customized_pokemon_has_moves 
                WHERE customized_pokemon_id = customizedPokemonId
            )
    );

    -- Identify if we need to create a new pokemon, can update the existing configuration, or one already exists
    SET @needs_new_pokemon = (@existing_pokemon_id IS NULL AND @old_configuration_in_use = 1);
    SET @can_update_pokemon = (@existing_pokemon_id IS NULL AND @old_configuration_in_use = 0);

    -- Create new pokemon if needed
    INSERT INTO customized_pokemon (pokemon_id, items_id, abilities_id, natures_id)
    SELECT (SELECT pokemon_id FROM customized_pokemon WHERE customized_pokemon_id = customizedPokemonId),
        (SELECT items_id FROM customized_pokemon WHERE customized_pokemon_id = customizedPokemonId),
        (SELECT abilities_id FROM customized_pokemon WHERE customized_pokemon_id = customizedPokemonId),
        (SELECT natures_id FROM customized_pokemon WHERE customized_pokemon_id = customizedPokemonId)
    WHERE @needs_new_pokemon = 1;

    -- Get the ID of the newly inserted pokemon
    SET @new_pokemon_id = IF(@needs_new_pokemon = 1, LAST_INSERT_ID(), NULL);

    -- Insert moves from the old pokemon configuration into the new pokemon
    INSERT INTO customized_pokemon_has_moves (customized_pokemon_id, moves_id)
    SELECT @new_pokemon_id, moves_id
    FROM customized_pokemon_has_moves
    WHERE customized_pokemon_id = customizedPokemonId
    AND @new_pokemon_id IS NOT NULL;

    -- Insert the new move into the new pokemon
    INSERT INTO customized_pokemon_has_moves (customized_pokemon_id, moves_id)
    SELECT @new_pokemon_id, moveId
    WHERE @new_pokemon_id IS NOT NULL;

    -- Add move to the existing configuration if needed
    INSERT INTO customized_pokemon_has_moves (customized_pokemon_id, moves_id)
    SELECT customizedPokemonId, moveId
    WHERE @can_update_pokemon = 1;

    -- Determine which ID to use to update the party
    SET @pokemon_id_to_use = CASE
        WHEN @existing_pokemon_id IS NOT NULL THEN @existing_pokemon_id
        WHEN @needs_new_pokemon = 1 THEN @new_pokemon_id
        ELSE customizedPokemonId
    END;

    -- Update the party to use the new pokemon
    UPDATE parties_has_customized_pokemon
    SET customized_pokemon_id = @pokemon_id_to_use
    WHERE parties_id = partyId AND customized_pokemon_id = customizedPokemonId;

    CALL cleanUnusedCustomizedPokemon();
END//

CREATE OR REPLACE PROCEDURE removeMoveFromPokemon(IN partyId INT, IN customizedPokemonId INT, IN moveId INT)
BEGIN
    -- Check if the old pokemon configuration is in another party
    SET @old_configuration_in_use = (
        SELECT COUNT(*) > 0
        FROM parties_has_customized_pokemon
        WHERE customized_pokemon_id = customizedPokemonId AND parties_id != partyId
    );

    -- Check if the new pokemon configuration already exists
    SET @existing_pokemon_id = (
        SELECT DISTINCT cp.customized_pokemon_id
        FROM customized_pokemon cp 
        JOIN customized_pokemon_has_moves cphm ON cp.customized_pokemon_id = cphm.customized_pokemon_id
        WHERE
            cp.pokemon_id = (SELECT pokemon_id FROM customized_pokemon WHERE customized_pokemon_id = customizedPokemonId) AND
            cp.items_id <=> (SELECT items_id FROM customized_pokemon WHERE customized_pokemon_id = customizedPokemonId) AND
            cp.abilities_id = (SELECT abilities_id FROM customized_pokemon WHERE customized_pokemon_id = customizedPokemonId) AND
            cp.natures_id = (SELECT natures_id FROM customized_pokemon WHERE customized_pokemon_id = customizedPokemonId) AND
            moveId = (
                SELECT moves_id 
                FROM customized_pokemon_has_moves 
                WHERE customized_pokemon_id = customizedPokemonId
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
                WHERE customized_pokemon_id = customizedPokemonId
            )
    );

    -- Identify if we need to create a new pokemon, can update the existing configuration, or one already exists
    SET @needs_new_pokemon = (@existing_pokemon_id IS NULL AND @old_configuration_in_use = 1);
    SET @can_update_pokemon = (@existing_pokemon_id IS NULL AND @old_configuration_in_use = 0);

    -- Create new pokemon if needed
    INSERT INTO customized_pokemon (pokemon_id, items_id, abilities_id, natures_id)
    SELECT (SELECT pokemon_id FROM customized_pokemon WHERE customized_pokemon_id = customizedPokemonId),
        (SELECT items_id FROM customized_pokemon WHERE customized_pokemon_id = customizedPokemonId),
        (SELECT abilities_id FROM customized_pokemon WHERE customized_pokemon_id = customizedPokemonId),
        (SELECT natures_id FROM customized_pokemon WHERE customized_pokemon_id = customizedPokemonId)
    WHERE @needs_new_pokemon = 1;

    -- Get the ID of the newly inserted pokemon
    SET @new_pokemon_id = IF(@needs_new_pokemon = 1, LAST_INSERT_ID(), NULL);

    -- Insert moves for the new pokemon, except the one we're deleting
    INSERT INTO customized_pokemon_has_moves (customized_pokemon_id, moves_id)
    SELECT @new_pokemon_id, moves_id
    FROM customized_pokemon_has_moves
    WHERE customized_pokemon_id = customizedPokemonId
    AND moves_id != moveId
    AND @new_pokemon_id IS NOT NULL;

    -- Delete move from existing configuration if needed
    DELETE FROM customized_pokemon_has_moves
    WHERE customized_pokemon_id = customizedPokemonId
    AND moves_id = moveId
    AND @can_update_pokemon = 1;

    -- Determine which ID to use to update the party
    SET @pokemon_id_to_use = CASE
        WHEN @existing_pokemon_id IS NOT NULL THEN @existing_pokemon_id
        WHEN @needs_new_pokemon = 1 THEN @new_pokemon_id
        ELSE customizedPokemonId
    END;

    -- Update the party to use the new pokemon
    UPDATE parties_has_customized_pokemon
    SET customized_pokemon_id = @pokemon_id_to_use
    WHERE parties_id = partyId AND customized_pokemon_id = customizedPokemonId;

    CALL cleanUnusedCustomizedPokemon();
END//

-- SELECT PROCEDURES
-- Note: All procedures with a searchQuery parameter use basic fuzzy matching.

CREATE OR REPLACE PROCEDURE getParties()
BEGIN
    SELECT parties_id AS "Party ID" FROM parties;
END//

-- Note: Use this when listing all abilities.
CREATE OR REPLACE PROCEDURE getAbilities(IN searchQuery VARCHAR(255))
BEGIN
    SELECT name AS "Ability Name" FROM abilities
    WHERE name LIKE CONCAT('%', searchQuery, '%');
END//

-- Note: Use this when listing abilities available to a specific pokemon.
CREATE OR REPLACE PROCEDURE getAbilitiesByPokemon(IN customizedPokemonId INT, IN searchQuery VARCHAR(255))
BEGIN
    SELECT a.name AS "Ability Name"
    FROM abilities a
    JOIN pokemon_has_abilities pha ON a.abilities_id = pha.abilities_id
    WHERE pha.pokemon_id = (SELECT pokemon_id FROM customized_pokemon WHERE customized_pokemon_id = customizedPokemonId)
    AND a.name LIKE CONCAT('%', searchQuery, '%');
END//

CREATE OR REPLACE PROCEDURE getItems(IN searchQuery VARCHAR(255))
BEGIN
    SELECT name AS "Item Name", description AS "Item Description" FROM items
    WHERE name LIKE CONCAT('%', searchQuery, '%');
END//

CREATE OR REPLACE PROCEDURE getNatures(IN searchQuery VARCHAR(255))
BEGIN
    SELECT name AS "Nature Name" FROM natures
    WHERE name LIKE CONCAT('%', searchQuery, '%');
END//

-- Note: No search query supported because the user will not select a type.
CREATE OR REPLACE PROCEDURE getTypes()
BEGIN
    SELECT name AS "Type Name" FROM types;
END//

CREATE OR REPLACE PROCEDURE getPokemon(IN searchQuery VARCHAR(255))
BEGIN
    WITH ranked_types AS (
        SELECT 
            p.pokemon_id,
            t.name AS type_name,
            ROW_NUMBER() OVER (PARTITION BY p.pokemon_id ORDER BY t.types_id) AS type_rank
        FROM pokemon p
        JOIN pokemon_has_types pht ON p.pokemon_id = pht.pokemon_id
        JOIN types t ON pht.types_id = t.types_id
        WHERE p.name LIKE CONCAT('%', searchQuery, '%')
    )
    SELECT 
        p.name AS "Pokemon Name",
        MAX(CASE WHEN rt.type_rank = 1 THEN rt.type_name END) AS "Primary Type",
        MAX(CASE WHEN rt.type_rank = 2 THEN rt.type_name END) AS "Secondary Type"
    FROM pokemon p
    LEFT JOIN ranked_types rt ON p.pokemon_id = rt.pokemon_id
    WHERE p.name LIKE CONCAT('%', searchQuery, '%')
    GROUP BY p.pokemon_id, p.name;
END//

-- Note: Use this when listing a specific customized pokemon's configuration.
CREATE OR REPLACE PROCEDURE getCustomizedPokemonById(IN customizedPokemonId INT)
BEGIN
    WITH move_ids AS (
        SELECT 
            customized_pokemon.customized_pokemon_id,
            MAX(CASE WHEN move_rank = 1 THEN moves_id END) AS move1_id,
            MAX(CASE WHEN move_rank = 2 THEN moves_id END) AS move2_id,
            MAX(CASE WHEN move_rank = 3 THEN moves_id END) AS move3_id,
            MAX(CASE WHEN move_rank = 4 THEN moves_id END) AS move4_id
        FROM customized_pokemon
        LEFT JOIN (
            SELECT 
                customized_pokemon_id, 
                moves_id, 
                ROW_NUMBER() OVER (PARTITION BY customized_pokemon_id ORDER BY moves_id) AS move_rank
            FROM customized_pokemon_has_moves
        ) moves ON customized_pokemon.customized_pokemon_id = moves.customized_pokemon_id
        WHERE customized_pokemon.customized_pokemon_id = customizedPokemonId
        GROUP BY customized_pokemon.customized_pokemon_id
    )
    SELECT 
        p.name AS "Pokemon Name",
        i.name AS "Item Name",
        a.name AS "Ability Name",
        n.name AS "Nature Name",
        m1.name AS "Move 1",
        m2.name AS "Move 2",
        m3.name AS "Move 3",
        m4.name AS "Move 4"
    FROM customized_pokemon cp
    JOIN pokemon p ON cp.pokemon_id = p.pokemon_id
    LEFT JOIN items i ON cp.items_id = i.items_id
    JOIN abilities a ON cp.abilities_id = a.abilities_id
    JOIN natures n ON cp.natures_id = n.natures_id
    JOIN move_ids mi ON cp.customized_pokemon_id = mi.customized_pokemon_id
    LEFT JOIN moves m1 ON mi.move1_id = m1.moves_id
    LEFT JOIN moves m2 ON mi.move2_id = m2.moves_id
    LEFT JOIN moves m3 ON mi.move3_id = m3.moves_id
    LEFT JOIN moves m4 ON mi.move4_id = m4.moves_id
    WHERE cp.customized_pokemon_id = customizedPokemonId;
END//

-- Note: Use this when listing all customized pokemon in a party.
CREATE OR REPLACE PROCEDURE getCustomizedPokemonByParty(IN partiesId INT)
BEGIN
    WITH move_ids AS (
        SELECT 
            cp.customized_pokemon_id,
            MAX(CASE WHEN move_rank = 1 THEN moves_id END) AS move1_id,
            MAX(CASE WHEN move_rank = 2 THEN moves_id END) AS move2_id,
            MAX(CASE WHEN move_rank = 3 THEN moves_id END) AS move3_id,
            MAX(CASE WHEN move_rank = 4 THEN moves_id END) AS move4_id
        FROM customized_pokemon cp
        JOIN parties_has_customized_pokemon phcp ON cp.customized_pokemon_id = phcp.customized_pokemon_id
        LEFT JOIN (
            SELECT 
                customized_pokemon_id, 
                moves_id, 
                ROW_NUMBER() OVER (PARTITION BY customized_pokemon_id ORDER BY moves_id) AS move_rank
            FROM customized_pokemon_has_moves
        ) moves ON cp.customized_pokemon_id = moves.customized_pokemon_id
        WHERE phcp.parties_id = partiesId
        GROUP BY cp.customized_pokemon_id
    )
    
    SELECT 
        p.name AS "Pokemon Name",
        i.name AS "Item Name",
        a.name AS "Ability Name",
        n.name AS "Nature Name",
        m1.name AS "Move 1",
        m2.name AS "Move 2",
        m3.name AS "Move 3",
        m4.name AS "Move 4"
    FROM customized_pokemon cp
    JOIN parties_has_customized_pokemon phcp ON cp.customized_pokemon_id = phcp.customized_pokemon_id
    JOIN pokemon p ON cp.pokemon_id = p.pokemon_id
    LEFT JOIN items i ON cp.items_id = i.items_id
    JOIN abilities a ON cp.abilities_id = a.abilities_id
    JOIN natures n ON cp.natures_id = n.natures_id
    JOIN move_ids mi ON cp.customized_pokemon_id = mi.customized_pokemon_id
    LEFT JOIN moves m1 ON mi.move1_id = m1.moves_id
    LEFT JOIN moves m2 ON mi.move2_id = m2.moves_id
    LEFT JOIN moves m3 ON mi.move3_id = m3.moves_id
    LEFT JOIN moves m4 ON mi.move4_id = m4.moves_id
    WHERE phcp.parties_id = partiesId;
END//

-- Note: Use this when listing all customized pokemon.
CREATE OR REPLACE PROCEDURE getCustomizedPokemon()
BEGIN
    WITH move_ids AS (
        SELECT 
            cp.customized_pokemon_id,
            MAX(CASE WHEN move_rank = 1 THEN moves_id END) AS move1_id,
            MAX(CASE WHEN move_rank = 2 THEN moves_id END) AS move2_id,
            MAX(CASE WHEN move_rank = 3 THEN moves_id END) AS move3_id,
            MAX(CASE WHEN move_rank = 4 THEN moves_id END) AS move4_id
        FROM customized_pokemon cp
        LEFT JOIN (
            SELECT 
                customized_pokemon_id, 
                moves_id, 
                ROW_NUMBER() OVER (PARTITION BY customized_pokemon_id ORDER BY moves_id) AS move_rank
            FROM customized_pokemon_has_moves
        ) moves ON cp.customized_pokemon_id = moves.customized_pokemon_id
        GROUP BY cp.customized_pokemon_id
    )
    SELECT 
        p.name AS "Pokemon Name",
        i.name AS "Item Name",
        a.name AS "Ability Name",
        n.name AS "Nature Name",
        m1.name AS "Move 1",
        m2.name AS "Move 2",
        m3.name AS "Move 3",
        m4.name AS "Move 4"
    FROM customized_pokemon cp
    JOIN pokemon p ON cp.pokemon_id = p.pokemon_id
    LEFT JOIN items i ON cp.items_id = i.items_id
    JOIN abilities a ON cp.abilities_id = a.abilities_id
    JOIN natures n ON cp.natures_id = n.natures_id
    JOIN move_ids mi ON cp.customized_pokemon_id = mi.customized_pokemon_id
    LEFT JOIN moves m1 ON mi.move1_id = m1.moves_id
    LEFT JOIN moves m2 ON mi.move2_id = m2.moves_id
    LEFT JOIN moves m3 ON mi.move3_id = m3.moves_id
    LEFT JOIN moves m4 ON mi.move4_id = m4.moves_id;
END//

-- Note: Use this when listing all moves.
CREATE OR REPLACE PROCEDURE getMoves(IN searchQuery VARCHAR(255))
BEGIN
    SELECT
        moves.name AS "Move Name",
        power AS "Power",
        description AS "Description",
        t.name AS "Type"
    FROM moves
    JOIN types t ON moves.types_id = t.types_id
    WHERE moves.name LIKE CONCAT('%', searchQuery, '%');
END//

-- Note: Use this when listing all moves available to a specific pokemon.
CREATE OR REPLACE PROCEDURE getMovesByPokemon(IN pokemonId INT, IN searchQuery VARCHAR(255))
BEGIN
    SELECT
        m.name AS "Move Name",
        m.power AS "Power",
        m.description AS "Description",
        t.name AS "Type"
    FROM moves m
    JOIN pokemon_has_moves phm ON m.moves_id = phm.moves_id
    JOIN types t ON m.types_id = t.types_id
    WHERE phm.pokemon_id = pokemonId
    AND m.name LIKE CONCAT('%', searchQuery, '%');
END//

DELIMITER ;
