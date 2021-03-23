-- set these values purely to cut down test time, as default ts trigger is
-- every min and 5 retries
alter system set gp_fts_probe_interval to 10;
alter system set gp_fts_probe_retries to 0;
select pg_reload_conf();

create table test_fts_session_reset(c1 int);

BEGIN;

insert into test_fts_session_reset select * from generate_series(1,20);

select dbid as id from gp_segment_configuration where content=0 and role = 'p' \gset db

select gp_inject_fault('fts_conn_startup_packet', 'fatal', :dbid) ;

select gp_request_fts_probe_scan();

do $$
begin
  for i in 1..120 loop
    if (select status = 'd' from gp_segment_configuration where content = 0 and role = 'm') then
      return;
    end if;
    perform pg_sleep(1);
  end loop;
end;
$$;

insert into test_fts_session_reset select * from generate_series(21,40);

select count(*) from test_fts_session_reset;

commit;

select count(*) from test_fts_session_reset;

select gp_inject_fault('fts_conn_startup_packet', 'reset', :dbid);

-- start_ignore

-- Wait until content 0 mirror is promoted otherwise, gprecoverseg
-- that runs after will fail.
do $$
declare
  y int;
begin
  for i in 1..120 loop
    begin
      select count(*) into y from gp_dist_random('gp_id');
      raise notice 'got % results, mirror must have been promoted', y;
      return;
    exception
      when others then
        raise notice 'mirror may not be promoted yet: %', sqlerrm;
        perform pg_sleep(0.5);
    end;
  end loop;
end;
$$;

\! gprecoverseg -av --no-progress
-- end_ignore

-- loop while segments come in sync
do $$
begin
  for i in 1..120 loop
    if (select count(*) = 0 from gp_segment_configuration where content = 0 and mode != 's') then
      return;
    end if;
    perform gp_request_fts_probe_scan();
  end loop;
end;
$$;
select role, preferred_role, mode, status from gp_segment_configuration where content = 0;

-- start_ignore
\! gprecoverseg -arv
-- end_ignore

-- loop while segments come in sync
do $$
begin
  for i in 1..120 loop
    if (select count(*) = 0 from gp_segment_configuration where content = 0 and mode != 's') then
      return;
    end if;
    perform gp_request_fts_probe_scan();
  end loop;
end;
$$;
select role, preferred_role, mode, status from gp_segment_configuration where content = 0;

alter system reset gp_fts_probe_interval;
alter system reset gp_fts_probe_retries;
select pg_reload_conf();

-- cleanup steps
select gp_inject_fault('all', 'reset', dbid)
from gp_segment_configuration where content = 0 and role = 'p';
