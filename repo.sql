CREATE EXTENSION pg_tle;
CREATE EXTENSION http;

CREATE TABLE IF NOT EXISTS tle_registry (
    name text primary key,
    repo text not null
    );

INSERT INTO tle_registry (name, repo) VALUES ('pgjwt', 'michelp/pgjwt') ON CONFLICT DO NOTHING;
INSERT INTO tle_registry (name, repo) VALUES ('pg_headerkit', 'supabase-community/pg_headerkit') ON CONFLICT DO NOTHING;

CREATE OR REPLACE FUNCTION install_extension(extname text) RETURNS bool LANGUAGE plpgsql
AS $$
    DECLARE
		repo text;
		response http_response;
        req_headers http_header[] = ARRAY[http_header('accept', 'application/vnd.github+json'),
                                          http_header('X-GitHub-Api-Version', '2022-11-28')];
        content jsonb;
        control_file text;
        comment text;
        default_version text;
		requires text;
	    sql_file text;
		version_files text[];
		update_files text[];
		version_regex text = '%s--([\d.]+).sql';
		update_regex text = '%s--([\d.]+)--([\d.]+).sql';
    BEGIN
    RAISE NOTICE 'Checking for existing %', extname;
    IF EXISTS (SELECT name from pg_available_extension_versions WHERE name = extname) THEN
        RAISE NOTICE '% is already in pg_available_extension_versions', extname;
        RETURN false;
    END IF;
    IF EXISTS (SELECT name from pgtle.available_extension_versions() WHERE name = extname) THEN
        RAISE NOTICE '% is already in pgtle.available_extension_versions', extname;
        RETURN false;
    END IF;
    IF NOT EXISTS (SELECT name from tle_registry WHERE name = extname) THEN
        RAISE NOTICE 'no entry for % in tle_registry', extname;
        RETURN false;
    END IF;
    SELECT t.repo INTO STRICT repo FROM tle_registry t WHERE name = extname;
    RAISE NOTICE 'Downloading % from repo %', extname, format('https://api.github.com/repos/%s/contents/%s.control', repo, extname);
    
    response = http(('GET',
              format('https://api.github.com/repos/%s/contents/%s.control', repo, extname),
              req_headers,
              NULL,
              NULL
    )::http_request);
    IF response.status != 200 THEN
        RAISE NOTICE 'Failed to download control file for %', extname;
        RETURN false;
    END IF;
    
    control_file = convert_from(decode((response.content::jsonb)->>'content', 'base64'), 'utf8');
	comment = coalesce((regexp_match(control_file, E'^\\s*comment\\s*=\\s*\'([\\d\\s\\w]*)\'$', 'n'))[1], '');
	default_version = coalesce((regexp_match(control_file, E'^\\s*default_version\\s*=\\s*\'([\\d.]*)\'$', 'n'))[1], '');
    requires = coalesce((regexp_match(control_file, E'^\\s*requires\\s*=\\s*(.*)$', 'n'))[1], '');

	raise notice 'comment: %, default_version: %, requires: %', comment, default_version, requires;
	
    response = http(('GET',
              format('https://api.github.com/repos/%s/contents/', repo),
              req_headers,
              NULL,
              NULL
    )::http_request);
    IF response.status != 200 THEN
        RAISE NOTICE 'Failed to download control file for %', extname;
        RETURN false;
    END IF;

	FOR content IN SELECT jsonb_array_elements(response.content::jsonb) LOOP
	    IF content->>'name' ~ format(version_regex, extname) THEN
		    version_files = array_append(version_files, content->>'name');
	    END IF;
	    IF content->>'name' ~ format(update_regex, extname) THEN
		    update_files = array_append(update_files, content->>'name');
	    END IF;
	END LOOP;
	
	FOREACH sql_file IN ARRAY coalesce(version_files, '{}'::text[]) LOOP
		IF (regexp_match(sql_file, format(version_regex, extname)))[1] = default_version THEN
			RAISE NOTICE 'Installing %', sql_file;
			response = http(('GET',
					  format('https://api.github.com/repos/%s/contents/%s', repo, sql_file),
					  req_headers,
					  NULL,
					  NULL
			)::http_request);
			IF response.status != 200 THEN
				RAISE NOTICE 'Failed to download control file for %', extname;
				RETURN false;
			END IF;

			PERFORM pgtle.install_extension(
				extname,
				(regexp_matches(sql_file, format(version_regex, extname)))[1],
				comment,
				convert_from(decode((response.content::jsonb)->>'content', 'base64'), 'utf8'),
				(select array_agg(trim(t)) from regexp_split_to_table(requires, ',') t));
	    END IF;
	END LOOP;
	
	FOREACH sql_file IN ARRAY coalesce(update_files, '{}'::text[]) LOOP
		RAISE NOTICE 'Installing update %', sql_file;
		response = http(('GET',
				  format('https://api.github.com/repos/%s/contents/%s', repo, sql_file),
				  req_headers,
				  NULL,
				  NULL
		)::http_request);
		IF response.status != 200 THEN
			RAISE NOTICE 'Failed to download update script for %', extname;
			RETURN false;
		END IF;

		PERFORM pgtle.install_update_path(
			extname,
			(regexp_matches(sql_file, format(update_regex, extname)))[1],
			(regexp_matches(sql_file, format(update_regex, extname)))[2],
			convert_from(decode((response.content::jsonb)->>'content', 'base64'), 'utf8'));
	END LOOP;

	PERFORM pgtle.set_default_version(extname, default_version);
    RETURN true;
    END;
$$;
