-- ============================================================
-- BlackChicken · Tareas de Salón asignadas (Supabase)
--
-- Conecta la app de planificación (bc1-ops / bc2-ops) con la app
-- de checklists (bc-checklist), usando el MISMO roster `people`.
--
-- ✅ NO hay nada que reemplazar. Copia y pega completo:
--    Supabase → SQL Editor → New query → Run.
--    Es idempotente: se puede correr de nuevo sin romper nada.
--
-- 🔑 Tu PIN queda como 7315 (Jonathan). Para cambiarlo después:
--    update people set pin='XXXX' where name='Jonathan Fosk';
-- ============================================================

-- ─────────────────────────────────────────────
-- 0) MIGRACIÓN desde la primera versión
--    Si ya corriste el SQL anterior, la tabla existe con la columna
--    llamada "time" (palabra reservada en Postgres). Esto la renombra
--    a time_due sin perder los datos. Si es la primera vez, no hace nada.
-- ─────────────────────────────────────────────
do $$
begin
  if to_regclass('public.salon_task_catalog') is not null
     and exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='salon_task_catalog' and column_name='time')
     and not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='salon_task_catalog' and column_name='time_due')
  then
    execute 'alter table public.salon_task_catalog rename column "time" to time_due';
    raise notice 'Columna "time" renombrada a time_due.';
  end if;
end $$;

-- ─────────────────────────────────────────────
-- 1) CATÁLOGO DE TAREAS
-- ─────────────────────────────────────────────
create table if not exists salon_task_catalog (
  id             text primary key,
  name           text not null,
  icon           text not null default 'checksq',
  time_due       text,                            -- '15:00' o 'cierre'
  priority       text not null default 'media' check (priority in ('alta','media','baja')),
  days           text[],                          -- null = todos los días
  is_break       boolean not null default false,
  photo_required boolean not null default true,
  locals         text[] not null default array['BC1','BC2'],
  active         boolean not null default true,
  sort_order     int not null default 0
);
alter table salon_task_catalog enable row level security;
drop policy if exists "read catalog" on salon_task_catalog;
create policy "read catalog" on salon_task_catalog for select to anon using (true);

insert into salon_task_catalog (id, name, icon, time_due, priority, days, is_break, photo_required, sort_order) values
  ('descanso',     'Descanso',                                   'coffee',   '16:00',  'media', null,             true,  false, 100),
  ('bebestibles',  'Rellenar bebestibles',                       'package',  '14:30',  'alta',  null,             false, true,  10),
  ('take_away',    'Rellenar take away',                         'utensils', '14:30',  'alta',  null,             false, true,  11),
  ('te_limonada',  'Producción Té y Limonada',                   'glass',    '14:30',  'alta',  null,             false, true,  12),
  ('barrer_piso',  'Barrer el piso',                             'broom',    '15:00',  'alta',  null,             false, true,  20),
  ('base_mesas',   'Limpiar base de las mesas',                  'checksq',  '15:00',  'media', null,             false, true,  21),
  ('bancos',       'Limpiar bancos',                             'checksq',  '15:00',  'media', null,             false, true,  22),
  ('ventanales',   'Limpiar ventanales',                         'window',   '15:00',  'media', null,             false, true,  23),
  ('visicooler',   'Limpieza Visicooler',                        'store',    '15:00',  'media', null,             false, true,  24),
  ('detras_refri', 'Limpiar detrás del refrigerador de bebidas', 'fridge',   '15:00',  'alta',  array['viernes'], false, true,  25),
  ('pantallas',    'Limpiar pantallas',                          'monitor',  '15:30',  'media', null,             false, true,  30),
  ('mesones',      'Limpiar mesones',                            'bath',     '15:30',  'alta',  null,             false, true,  31),
  ('loza',         'Repasar loza',                               'glass',    '15:30',  'media', null,             false, true,  32),
  ('aseo_salon',   'Aseo Cocina y Salón',                        'bath',     '15:30',  'alta',  null,             false, true,  33),
  ('carrito',      'Carrito y Cajas',                            'cart',     'cierre', 'baja',  null,             false, true,  40)
on conflict (id) do nothing;

-- Revisión de pedidos delivery: solo BC1 (BC2 no tiene delivery)
insert into salon_task_catalog (id, name, icon, time_due, priority, days, is_break, photo_required, locals, sort_order)
  values ('delivery_check','Revisión Pedidos Delivery','truck','13:00','alta',null,false,true,array['BC1'],5)
on conflict (id) do nothing;

-- ─────────────────────────────────────────────
-- 2) ASIGNACIONES SEMANALES
--    Una fila = a esta persona, este día de esta semana, esta tarea.
-- ─────────────────────────────────────────────
create table if not exists salon_assignments (
  id          uuid primary key default gen_random_uuid(),
  local       text not null check (local in ('BC1','BC2','BC3')),
  week_start  date not null,                       -- lunes de la semana
  day_name    text not null check (day_name in ('lunes','martes','miercoles','jueves','viernes','sabado','domingo')),
  person_id   int  not null references people(id) on delete cascade,
  task_id     text not null references salon_task_catalog(id) on delete cascade,
  assigned_by int  references people(id),
  created_at  timestamptz not null default now(),
  unique (local, week_start, day_name, person_id, task_id)
);
alter table salon_assignments enable row level security;
drop policy if exists "read assignments" on salon_assignments;
create policy "read assignments" on salon_assignments for select to anon using (true);
create index if not exists idx_salon_assign on salon_assignments (local, week_start, day_name);

-- ─────────────────────────────────────────────
-- 3) REGISTRO DE EJECUCIÓN (con foto)
-- ─────────────────────────────────────────────
create table if not exists salon_task_log (
  id         uuid primary key default gen_random_uuid(),
  local      text not null,
  work_date  date not null,
  person_id  int  not null references people(id) on delete cascade,
  task_id    text not null,
  task_name  text,
  time_due   text,                                 -- hora asignada, congelada al registrar
  done_at    timestamptz not null default now(),
  photo_url  text,
  source     text not null default 'checklist',
  unique (local, work_date, person_id, task_id)
);
alter table salon_task_log enable row level security;
drop policy if exists "read salon log" on salon_task_log;
create policy "read salon log" on salon_task_log for select to anon using (true);
create index if not exists idx_salon_log_dia on salon_task_log (local, work_date);

-- ─────────────────────────────────────────────
-- 4) ENVÍO DE TURNO
-- ─────────────────────────────────────────────
create table if not exists salon_shift_submits (
  local      text not null,
  work_date  date not null,
  person_id  int  not null references people(id) on delete cascade,
  done       int  not null default 0,
  total      int  not null default 0,
  sent_at    timestamptz not null default now(),
  primary key (local, work_date, person_id)
);
alter table salon_shift_submits enable row level security;
drop policy if exists "read shift submits" on salon_shift_submits;
create policy "read shift submits" on salon_shift_submits for select to anon using (true);

-- ─────────────────────────────────────────────
-- 5) ROSTER: sincronizar con el organigrama
--    Al 29-jul-2026 el organigrama tiene 2 garzonas que NO existen en
--    `people` (por lo tanto hoy no pueden entrar a NINGUNA app), y 1
--    persona en `people` que ya no está en el organigrama.
--    Además se agrega a Jonathan, que no estaba en el roster.
-- ─────────────────────────────────────────────
insert into people (name, role, local, station, pin, active)
select * from (values
  ('Catalina Jaque','Garzona Part Time','AMBOS','S','4812',true),
  ('Francisca Ortiz','Garzona Part Time','AMBOS','S','5237',true),
  ('Jonathan Fosk','Dueño','AMBOS','B','7315',true)
) as v(name,role,local,station,pin,active)
where not exists (select 1 from people p where p.name = v.name);

-- Maria Paula Rincon ya no aparece en el organigrama → desactivar.
-- Comenta esta línea si sigue trabajando.
update people set active = false where name = 'Maria Paula Rincon';

-- ─────────────────────────────────────────────
-- 6) QUIÉN PUEDE ASIGNAR
--    Los jefes de garzones (Cristóbal y Mariangel) + Jonathan.
--    Nadie más, y se valida en el servidor: no se puede saltar
--    tocando el código de la app.
-- ─────────────────────────────────────────────
create or replace function salon_can_assign(p_person int)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from people
     where id = p_person and active
       and ( (station = 'S' and (role ilike '%jefe%garzon%' or role ilike '%jefa%garzon%'))
             or role ilike 'due%o' )
  );
$$;
grant execute on function salon_can_assign(int) to anon;

-- ─────────────────────────────────────────────
-- 7) LECTURA: tareas de una persona en un día
--    Es lo único que necesita bc-checklist para mostrarlas.
-- ─────────────────────────────────────────────
create or replace function salon_my_tasks(p_person int, p_local text, p_date date)
returns table (
  task_id text, task_name text, icon text, time_due text, priority text,
  is_break boolean, photo_required boolean,
  done_at timestamptz, photo_url text
)
language sql stable security definer set search_path = public as $$
  with dia as (
    select case extract(isodow from p_date)
      when 1 then 'lunes' when 2 then 'martes' when 3 then 'miercoles'
      when 4 then 'jueves' when 5 then 'viernes' when 6 then 'sabado'
      else 'domingo' end as d,
      (p_date - (extract(isodow from p_date)::int - 1))::date as lunes
  )
  select c.id, c.name, c.icon, c.time_due, c.priority,
         c.is_break, c.photo_required,
         l.done_at, l.photo_url
    from salon_assignments a
    cross join dia
    join salon_task_catalog c on c.id = a.task_id and c.active
    left join salon_task_log l
      on l.local = a.local and l.work_date = p_date
     and l.person_id = a.person_id and l.task_id = a.task_id
   where a.person_id  = p_person
     and a.local      = p_local
     and a.day_name   = dia.d
     and a.week_start = dia.lunes
   order by (c.time_due = 'cierre'), c.time_due, c.sort_order;
$$;
grant execute on function salon_my_tasks(int, text, date) to anon;

-- ─────────────────────────────────────────────
-- 8) ESCRITURA: marcar una tarea (valida PIN + foto obligatoria)
-- ─────────────────────────────────────────────
create or replace function salon_log_task(
  p_person int, p_pin text, p_local text, p_task text, p_photo text, p_date date default null
) returns void language plpgsql security definer set search_path = public as $$
declare v_req boolean; v_name text; v_time text; v_date date;
begin
  if not verify_pin(p_person, p_pin) then raise exception 'PIN invalido'; end if;
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

-- Desmarcar (por si se equivocó)
create or replace function salon_unlog_task(p_person int, p_pin text, p_local text, p_task text, p_date date default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not verify_pin(p_person, p_pin) then raise exception 'PIN invalido'; end if;
  delete from salon_task_log
   where local = p_local and work_date = coalesce(p_date, current_date)
     and person_id = p_person and task_id = p_task;
end $$;
grant execute on function salon_unlog_task(int, text, text, text, date) to anon;

-- Enviar turno
create or replace function salon_submit_shift(p_person int, p_pin text, p_local text, p_done int, p_total int)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not verify_pin(p_person, p_pin) then raise exception 'PIN invalido'; end if;
  insert into salon_shift_submits (local, work_date, person_id, done, total, sent_at)
       values (p_local, current_date, p_person, p_done, p_total, now())
  on conflict (local, work_date, person_id)
    do update set done = excluded.done, total = excluded.total, sent_at = now();
end $$;
grant execute on function salon_submit_shift(int, text, text, int, int) to anon;

-- ─────────────────────────────────────────────
-- 9) ASIGNAR: reemplaza la asignación de un día completo
--    p_assign = {"12": ["barrer_piso","bancos"], "15": ["mesones"]}
--    (clave = person_id como texto, valor = lista de task_id)
-- ─────────────────────────────────────────────
create or replace function salon_set_day(
  p_actor int, p_pin text, p_local text, p_week date, p_day text, p_assign jsonb
) returns void language plpgsql security definer set search_path = public as $$
declare k text; v jsonb; t text;
begin
  if not verify_pin(p_actor, p_pin) then raise exception 'PIN invalido'; end if;
  if not salon_can_assign(p_actor)  then raise exception 'solo los jefes de garzones pueden asignar'; end if;

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
-- 10) PANEL: semana completa con cumplimiento
-- ─────────────────────────────────────────────
create or replace function salon_week_report(p_local text, p_week date)
returns table (
  day_name text, work_date date, person_id int, person_name text,
  task_id text, task_name text, time_due text, priority text, is_break boolean,
  done_at timestamptz, photo_url text
)
language sql stable security definer set search_path = public as $$
  select a.day_name,
         (p_week + (array_position(array['lunes','martes','miercoles','jueves','viernes','sabado','domingo'], a.day_name) - 1))::date,
         p.id, p.name,
         c.id, c.name, c.time_due, c.priority, c.is_break,
         l.done_at, l.photo_url
    from salon_assignments a
    join people p on p.id = a.person_id
    join salon_task_catalog c on c.id = a.task_id and c.active
    left join salon_task_log l
      on l.local = a.local and l.person_id = a.person_id and l.task_id = a.task_id
     and l.work_date = (p_week + (array_position(array['lunes','martes','miercoles','jueves','viernes','sabado','domingo'], a.day_name) - 1))::date
   where a.local = p_local and a.week_start = p_week
   order by array_position(array['lunes','martes','miercoles','jueves','viernes','sabado','domingo'], a.day_name),
            p.name, (c.time_due = 'cierre'), c.time_due;
$$;
grant execute on function salon_week_report(text, date) to anon;

-- ─────────────────────────────────────────────
-- 11) ADMIN del catálogo — protegido con TU PIN (7315)
--     No se otorga a anon: solo se usa desde este editor SQL.
--     Ejemplo para cambiar la hora de una tarea:
--       select salon_admin_upsert_task('7315','loza','Repasar loza','glass',
--              '16:00','media',null,false,true,array['BC1','BC2'],32);
-- ─────────────────────────────────────────────
create or replace function salon_admin_upsert_task(
  p_master text, p_id text, p_name text, p_icon text, p_time text,
  p_priority text, p_days text[], p_is_break boolean, p_photo_required boolean,
  p_locals text[], p_sort int
) returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from people where name='Jonathan Fosk' and pin=p_master and active)
    then raise exception 'no autorizado'; end if;
  insert into salon_task_catalog (id, name, icon, time_due, priority, days, is_break, photo_required, locals, sort_order)
       values (p_id, p_name, p_icon, p_time, p_priority, p_days, p_is_break, p_photo_required, coalesce(p_locals, array['BC1','BC2']), coalesce(p_sort,0))
  on conflict (id) do update set
       name = excluded.name, icon = excluded.icon, time_due = excluded.time_due,
       priority = excluded.priority, days = excluded.days, is_break = excluded.is_break,
       photo_required = excluded.photo_required, locals = excluded.locals, sort_order = excluded.sort_order;
end $$;

create or replace function salon_admin_set_task_active(p_master text, p_id text, p_active boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from people where name='Jonathan Fosk' and pin=p_master and active)
    then raise exception 'no autorizado'; end if;
  update salon_task_catalog set active = p_active where id = p_id;
end $$;

-- ─────────────────────────────────────────────
-- 12) VERIFICACIÓN
--     Esperado: 16 tareas · 3 pueden asignar · 11 personas de salón
-- ─────────────────────────────────────────────
select count(*) as tareas_en_catalogo from salon_task_catalog;
select id, name, role from people where salon_can_assign(id) order by name;
select id, name, role, local from people where station = 'S' and active order by name;
