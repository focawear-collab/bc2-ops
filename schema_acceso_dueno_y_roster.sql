-- ============================================================
-- BlackChicken · Acceso de dueño oculto a las tareas de salón
--
-- Jonathan queda FUERA del roster visible (no aparece en la lista
-- "¿Quién eres?" de bc-checklist ni en ninguna pantalla del equipo),
-- pero puede entrar a bc1-ops / bc2-ops con su PIN y asignar.
--
-- ✅ Nada que reemplazar. Copia y pega completo:
--    Supabase → SQL Editor → New query → Run.
--    Idempotente: se puede correr de nuevo sin romper nada.
--
-- 🔑 Tu PIN sigue siendo 7315. Para cambiarlo:
--    update people set pin='XXXX' where name='Jonathan Fosk';
-- ============================================================

-- ─────────────────────────────────────────────
-- 1) Asegurar que la fila del dueño existe y queda OCULTA
--    active = false la saca de people_public, que es lo que leen
--    las dos apps para armar la lista de personas.
-- ─────────────────────────────────────────────
insert into people (name, role, local, station, pin, active)
select 'Jonathan Fosk','Dueño','AMBOS','B','7315',false
where not exists (select 1 from people where name = 'Jonathan Fosk');

update people set role = 'Dueño', active = false where name = 'Jonathan Fosk';

-- ─────────────────────────────────────────────
-- 2) Validación de PIN que acepta al dueño aunque esté oculto
--    Para todos los demás se comporta igual que verify_pin.
--    No se otorga a anon: solo la usan las funciones de abajo.
-- ─────────────────────────────────────────────
create or replace function salon_pin_ok(p_person int, p_pin text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from people
     where id = p_person and pin = p_pin
       and (active or role ilike 'due%o')
  );
$$;

-- ─────────────────────────────────────────────
-- 3) Login del dueño: devuelve su id solo si el PIN calza
--    Devuelve 0 filas si el PIN es incorrecto. No expone el PIN.
-- ─────────────────────────────────────────────
create or replace function salon_owner_login(p_pin text)
returns table (id int, name text, role text)
language sql stable security definer set search_path = public as $$
  select p.id, split_part(p.name,' ',1), p.role
    from people p
   where p.role ilike 'due%o' and p.pin = p_pin
   limit 1;
$$;
grant execute on function salon_owner_login(text) to anon;

-- ─────────────────────────────────────────────
-- 4) Permiso de asignar: jefes de garzones activos + el dueño oculto
-- ─────────────────────────────────────────────
create or replace function salon_can_assign(p_person int)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from people
     where id = p_person
       and ( (active and station = 'S'
              and (role ilike '%jefe%garzon%' or role ilike '%jefa%garzon%'))
             or role ilike 'due%o' )
  );
$$;
grant execute on function salon_can_assign(int) to anon;

-- ─────────────────────────────────────────────
-- 5) Las funciones de escritura pasan a usar salon_pin_ok
--    (mismo comportamiento para el equipo; habilita al dueño oculto)
-- ─────────────────────────────────────────────
create or replace function salon_set_day(
  p_actor int, p_pin text, p_local text, p_week date, p_day text, p_assign jsonb
) returns void language plpgsql security definer set search_path = public as $$
declare k text; v jsonb; t text;
begin
  if not salon_pin_ok(p_actor, p_pin) then raise exception 'PIN invalido'; end if;
  if not salon_can_assign(p_actor)    then raise exception 'solo los jefes de garzones pueden asignar'; end if;

  delete from salon_assignments
   where local = p_local and week_start = p_week and day_name = p_day;

  for k, v in select * from jsonb_each(p_assign) loop
    for t in select jsonb_array_elements_text(v) loop
      insert into salon_assignments (local, week_start, day_name, person_id, task_id, assigned_by)
           values (p_local, p_week, p_day, k::int, t, p_actor)
      on conflict do nothing;
    end loop;
  end loop;
end $$;
grant execute on function salon_set_day(int, text, text, date, text, jsonb) to anon;

create or replace function salon_log_task(
  p_person int, p_pin text, p_local text, p_task text, p_photo text, p_date date default null
) returns void language plpgsql security definer set search_path = public as $$
declare v_req boolean; v_name text; v_time text; v_date date;
begin
  if not salon_pin_ok(p_person, p_pin) then raise exception 'PIN invalido'; end if;
  v_date := coalesce(p_date, current_date);

  select name, time_due, photo_required into v_name, v_time, v_req
    from salon_task_catalog where id = p_task and active;
  if not found then raise exception 'tarea no existe'; end if;

  if v_req and coalesce(p_photo,'') = '' then
    raise exception 'esta tarea requiere foto';
  end if;

  insert into salon_task_log (local, work_date, person_id, task_id, task_name, time_due, photo_url, done_at)
       values (p_local, v_date, p_person, p_task, v_name, v_time, nullif(p_photo,''), now())
  on conflict (local, work_date, person_id, task_id)
    do update set photo_url = excluded.photo_url, done_at = now();
end $$;
grant execute on function salon_log_task(int, text, text, text, text, date) to anon;

create or replace function salon_unlog_task(p_person int, p_pin text, p_local text, p_task text, p_date date default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not salon_pin_ok(p_person, p_pin) then raise exception 'PIN invalido'; end if;
  delete from salon_task_log
   where local = p_local and work_date = coalesce(p_date, current_date)
     and person_id = p_person and task_id = p_task;
end $$;
grant execute on function salon_unlog_task(int, text, text, text, date) to anon;

create or replace function salon_submit_shift(p_person int, p_pin text, p_local text, p_done int, p_total int)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not salon_pin_ok(p_person, p_pin) then raise exception 'PIN invalido'; end if;
  insert into salon_shift_submits (local, work_date, person_id, done, total, sent_at)
       values (p_local, current_date, p_person, p_done, p_total, now())
  on conflict (local, work_date, person_id)
    do update set done = excluded.done, total = excluded.total, sent_at = now();
end $$;
grant execute on function salon_submit_shift(int, text, text, int, int) to anon;

-- ─────────────────────────────────────────────
-- 6) VERIFICACIÓN
--    Esperado: login devuelve 1 fila · puede asignar = true ·
--    NO aparece en el roster visible · el equipo sigue intacto
-- ─────────────────────────────────────────────
select 'login con 7315' as prueba, * from salon_owner_login('7315');
select 'login con PIN malo' as prueba, count(*) as filas from salon_owner_login('0000');
select 'dueño puede asignar' as prueba,
       salon_can_assign((select id from people where name='Jonathan Fosk')) as resultado;
select 'aparece en el roster visible' as prueba,
       exists (select 1 from people_public where name='Jonathan Fosk') as resultado;
select 'personas visibles' as prueba, count(*) as total from people_public;

-- ============================================================
-- PARTE 2 · ROSTER SEMANAL: quién trabaja en cada local esta semana
--
-- Los garzones rotan entre BC1 y BC2. Cada semana el jefe de garzones
-- elige quiénes están con él; el resto queda automáticamente en el otro
-- local. Una persona está en exactamente un local por semana.
-- ============================================================

create table if not exists salon_week_roster (
  week_start date not null,
  person_id   int  not null references people(id) on delete cascade,
  local       text not null check (local in ('BC1','BC2','BC3')),
  set_by      int  references people(id),
  updated_at  timestamptz not null default now(),
  primary key (week_start, person_id)
);
alter table salon_week_roster enable row level security;
drop policy if exists "read week roster" on salon_week_roster;
create policy "read week roster" on salon_week_roster for select to anon using (true);
create index if not exists idx_week_roster on salon_week_roster (week_start, local);

-- El otro local (con dos locales, el complemento)
create or replace function salon_otro_local(p_local text)
returns text language sql immutable as $$
  select case p_local when 'BC1' then 'BC2' when 'BC2' then 'BC1' else 'BC1' end;
$$;

-- ─────────────────────────────────────────────
-- Definir el equipo de la semana.
-- p_ids = quiénes están en p_local. TODOS los demás garzones activos
-- quedan en el otro local automáticamente.
-- ─────────────────────────────────────────────
create or replace function salon_set_week_roster(
  p_actor int, p_pin text, p_week date, p_local text, p_ids int[]
) returns void language plpgsql security definer set search_path = public as $$
declare otro text;
begin
  if not salon_pin_ok(p_actor, p_pin) then raise exception 'PIN invalido'; end if;
  if not salon_can_assign(p_actor)    then raise exception 'solo los jefes de garzones pueden definir el equipo'; end if;

  otro := salon_otro_local(p_local);

  delete from salon_week_roster where week_start = p_week;

  insert into salon_week_roster (week_start, person_id, local, set_by)
  select p_week, pe.id,
         case when pe.id = any(coalesce(p_ids, '{}'::int[])) then p_local else otro end,
         p_actor
    from people pe
   where pe.active and pe.station = 'S';

  /* Si alguien cambió de local, sus tareas de esa semana en el local
     anterior dejan de tener sentido: se limpian. */
  delete from salon_assignments a
   using salon_week_roster r
   where a.week_start = p_week
     and r.week_start = p_week
     and r.person_id  = a.person_id
     and r.local     <> a.local;
end $$;
grant execute on function salon_set_week_roster(int, text, date, text, int[]) to anon;

-- ─────────────────────────────────────────────
-- Leer el equipo de una semana y local.
-- Si la semana todavía no tiene roster definido, devuelve 0 filas
-- y la app muestra el selector.
-- ─────────────────────────────────────────────
create or replace function salon_week_roster_get(p_week date, p_local text)
returns table (person_id int, name text, role text, en_este_local boolean)
language sql stable security definer set search_path = public as $$
  select r.person_id, p.name, p.role, (r.local = p_local)
    from salon_week_roster r
    join people p on p.id = r.person_id and p.active
   where r.week_start = p_week
   order by (r.local = p_local) desc,
            (p.role ilike '%jefe%garzon%' or p.role ilike '%jefa%garzon%') desc,
            p.name;
$$;
grant execute on function salon_week_roster_get(date, text) to anon;

-- ─────────────────────────────────────────────
-- Guardia: no se puede asignar una tarea a alguien que esa semana
-- no está en ese local. Solo aplica si la semana ya tiene roster.
-- ─────────────────────────────────────────────
create or replace function salon_set_day(
  p_actor int, p_pin text, p_local text, p_week date, p_day text, p_assign jsonb
) returns void language plpgsql security definer set search_path = public as $$
declare k text; v jsonb; t text; hay_roster boolean; malo text;
begin
  if not salon_pin_ok(p_actor, p_pin) then raise exception 'PIN invalido'; end if;
  if not salon_can_assign(p_actor)    then raise exception 'solo los jefes de garzones pueden asignar'; end if;

  select exists (select 1 from salon_week_roster where week_start = p_week) into hay_roster;
  if hay_roster then
    select string_agg(pe.name, ', ') into malo
      from jsonb_each(p_assign) e
      join people pe on pe.id = e.key::int
     where not exists (
       select 1 from salon_week_roster r
        where r.week_start = p_week and r.person_id = e.key::int and r.local = p_local);
    if malo is not null then
      raise exception 'esta semana % no trabaja(n) en este local', malo;
    end if;
  end if;

  delete from salon_assignments
   where local = p_local and week_start = p_week and day_name = p_day;

  for k, v in select * from jsonb_each(p_assign) loop
    for t in select jsonb_array_elements_text(v) loop
      insert into salon_assignments (local, week_start, day_name, person_id, task_id, assigned_by)
           values (p_local, p_week, p_day, k::int, t, p_actor)
      on conflict do nothing;
    end loop;
  end loop;
end $$;
grant execute on function salon_set_day(int, text, text, date, text, jsonb) to anon;

-- ─────────────────────────────────────────────
-- VERIFICACIÓN PARTE 2
-- ─────────────────────────────────────────────
select 'garzones activos' as prueba, count(*) as total from people_public where station='S';
