-- ============================================================
-- 《面壁者互动小说》讨论交流区 · Supabase 建表脚本（完整版 v2）
-- 用法：Supabase 控制台 → 左侧 SQL Editor → 整段粘贴 → RUN
-- 可重复执行；已经执行过 v1 的项目再跑这一段也会自动补齐新增字段
-- 内容：留言 / 点赞 / 评论（含评论的回复、评论点赞）/ 未读消息 / 置顶
-- ============================================================

-- 1) 留言（管理员可置顶）
create table if not exists public.posts (
  id            bigserial primary key,
  user_id       uuid not null references auth.users(id) on delete cascade,
  username      text not null,
  content       text not null,
  like_count    int  not null default 0,
  comment_count int  not null default 0,
  pinned        boolean not null default false,
  created_at    timestamptz not null default now()
);

-- 2) 留言点赞
create table if not exists public.post_likes (
  post_id    bigint not null references public.posts(id) on delete cascade,
  user_id    uuid   not null references auth.users(id) on delete cascade,
  username   text   not null default '',
  created_at timestamptz not null default now(),
  primary key (post_id, user_id)
);

-- 3) 评论（parent_id 指向被回复的那条评论；reply_to 记被回复者昵称）
create table if not exists public.post_comments (
  id         bigserial primary key,
  post_id    bigint not null references public.posts(id) on delete cascade,
  user_id    uuid   not null references auth.users(id) on delete cascade,
  username   text   not null,
  content    text   not null,
  parent_id  bigint,
  reply_to   text not null default '',
  like_count int  not null default 0,
  created_at timestamptz not null default now()
);

-- 4) 评论点赞
create table if not exists public.comment_likes (
  comment_id bigint not null references public.post_comments(id) on delete cascade,
  user_id    uuid   not null references auth.users(id) on delete cascade,
  username   text   not null default '',
  created_at timestamptz not null default now(),
  primary key (comment_id, user_id)
);

-- 5) 消息
create table if not exists public.notifications (
  id         bigserial primary key,
  user_id    uuid not null references auth.users(id) on delete cascade,   -- 收件人
  kind       text not null,                                              -- like | comment | reply | clike
  post_id    bigint not null references public.posts(id) on delete cascade,
  comment_id bigint,
  actor      text not null default '',
  excerpt    text not null default '',
  seen       boolean not null default false,
  created_at timestamptz not null default now()
);

-- 6) 老项目补字段（v1 已建过表时，这一段负责加列，重复执行无害）
alter table public.posts          add column if not exists pinned     boolean not null default false;
alter table public.post_comments  add column if not exists parent_id  bigint;
alter table public.post_comments  add column if not exists reply_to   text not null default '';
alter table public.post_comments  add column if not exists like_count int  not null default 0;
alter table public.notifications  add column if not exists comment_id bigint;

create index if not exists posts_created_idx on public.posts (created_at desc);
create index if not exists posts_pinned_idx on public.posts (pinned desc, created_at desc);
create index if not exists notifications_user_idx on public.notifications (user_id, seen, created_at desc);
create index if not exists comments_post_idx on public.post_comments (post_id, created_at);

-- 7) 触发器：留言点赞 / 取消
create or replace function public.on_like_insert()
returns trigger language plpgsql security definer as $$
begin
  update public.posts set like_count = like_count + 1 where id = new.post_id;
  insert into public.notifications (user_id, kind, post_id, actor, excerpt)
  select p.user_id, 'like', p.id, new.username, left(p.content, 60)
  from public.posts p
  where p.id = new.post_id and p.user_id <> new.user_id;
  return new;
end;
$$;

create or replace function public.on_like_delete()
returns trigger language plpgsql security definer as $$
begin
  update public.posts set like_count = greatest(like_count - 1, 0) where id = old.post_id;
  return old;
end;
$$;

drop trigger if exists trg_like_insert on public.post_likes;
create trigger trg_like_insert after insert on public.post_likes
for each row execute function public.on_like_insert();

drop trigger if exists trg_like_delete on public.post_likes;
create trigger trg_like_delete after delete on public.post_likes
for each row execute function public.on_like_delete();

-- 8) 触发器：评论 / 回复
--    顶层评论 → 通知留言作者（kind=comment）
--    回复别人的评论 → 通知被回复的那位（kind=reply）
create or replace function public.on_comment_insert()
returns trigger language plpgsql security definer as $$
declare
  owner uuid;
begin
  update public.posts set comment_count = comment_count + 1 where id = new.post_id;

  if new.parent_id is null then
    select p.user_id into owner from public.posts p where p.id = new.post_id;
    if owner is not null and owner <> new.user_id then
      insert into public.notifications (user_id, kind, post_id, comment_id, actor, excerpt)
      values (owner, 'comment', new.post_id, new.id, new.username, left(new.content, 60));
    end if;
  else
    select c.user_id into owner from public.post_comments c where c.id = new.parent_id;
    if owner is not null and owner <> new.user_id then
      insert into public.notifications (user_id, kind, post_id, comment_id, actor, excerpt)
      values (owner, 'reply', new.post_id, new.id, new.username, left(new.content, 60));
    end if;
  end if;

  return new;
end;
$$;

create or replace function public.on_comment_delete()
returns trigger language plpgsql security definer as $$
begin
  update public.posts set comment_count = greatest(comment_count - 1, 0) where id = old.post_id;
  -- 评论被删掉后，指向这条评论的消息也一并清掉（别人的回复本身保留）
  delete from public.notifications where comment_id = old.id;
  return old;
end;
$$;

drop trigger if exists trg_comment_insert on public.post_comments;
create trigger trg_comment_insert after insert on public.post_comments
for each row execute function public.on_comment_insert();

drop trigger if exists trg_comment_delete on public.post_comments;
create trigger trg_comment_delete after delete on public.post_comments
for each row execute function public.on_comment_delete();

-- 9) 触发器：评论点赞 / 取消 → 通知该评论作者
create or replace function public.on_clike_insert()
returns trigger language plpgsql security definer as $$
declare
  c_owner uuid;
  c_post  bigint;
begin
  update public.post_comments set like_count = like_count + 1 where id = new.comment_id;
  select c.user_id, c.post_id into c_owner, c_post from public.post_comments c where c.id = new.comment_id;
  if c_owner is not null and c_owner <> new.user_id then
    insert into public.notifications (user_id, kind, post_id, comment_id, actor, excerpt)
    select c_owner, 'clike', c_post, new.comment_id, new.username, left(c.content, 60)
    from public.post_comments c where c.id = new.comment_id;
  end if;
  return new;
end;
$$;

create or replace function public.on_clike_delete()
returns trigger language plpgsql security definer as $$
begin
  update public.post_comments set like_count = greatest(like_count - 1, 0) where id = old.comment_id;
  return old;
end;
$$;

drop trigger if exists trg_clike_insert on public.comment_likes;
create trigger trg_clike_insert after insert on public.comment_likes
for each row execute function public.on_clike_insert();

drop trigger if exists trg_clike_delete on public.comment_likes;
create trigger trg_clike_delete after delete on public.comment_likes
for each row execute function public.on_clike_delete();

-- 10) 开行级安全
alter table public.posts         enable row level security;
alter table public.post_likes    enable row level security;
alter table public.post_comments enable row level security;
alter table public.comment_likes enable row level security;
alter table public.notifications enable row level security;

-- 留言：所有人可看；登录玩家可发；只有管理员能删、能改（改只用来置顶）
drop policy if exists "posts read all" on public.posts;
create policy "posts read all" on public.posts
  for select using (true);

drop policy if exists "posts insert self" on public.posts;
create policy "posts insert self" on public.posts
  for insert with check (auth.uid() = user_id);

drop policy if exists "posts delete admin" on public.posts;
drop policy if exists "posts delete self or admin" on public.posts;
create policy "posts delete self or admin" on public.posts
  for delete using (auth.uid() = user_id or public.is_admin());

drop policy if exists "posts update admin" on public.posts;
create policy "posts update admin" on public.posts
  for update using (public.is_admin()) with check (public.is_admin());

-- 留言点赞
drop policy if exists "likes read all" on public.post_likes;
create policy "likes read all" on public.post_likes
  for select using (true);

drop policy if exists "likes insert self" on public.post_likes;
create policy "likes insert self" on public.post_likes
  for insert with check (auth.uid() = user_id);

drop policy if exists "likes delete self or admin" on public.post_likes;
create policy "likes delete self or admin" on public.post_likes
  for delete using (auth.uid() = user_id or public.is_admin());

-- 评论
drop policy if exists "comments read all" on public.post_comments;
create policy "comments read all" on public.post_comments
  for select using (true);

drop policy if exists "comments insert self" on public.post_comments;
create policy "comments insert self" on public.post_comments
  for insert with check (auth.uid() = user_id);

drop policy if exists "comments delete admin" on public.post_comments;
drop policy if exists "comments delete self or admin" on public.post_comments;
create policy "comments delete self or admin" on public.post_comments
  for delete using (auth.uid() = user_id or public.is_admin());

-- 说明：删评论不会连带删别人的回复（parent_id 只是引用，没有级联）；
--       删留言才会把它下面的评论一起级联删除，因为 post_id 上挂了 on delete cascade。

-- 评论点赞
drop policy if exists "clikes read all" on public.comment_likes;
create policy "clikes read all" on public.comment_likes
  for select using (true);

drop policy if exists "clikes insert self" on public.comment_likes;
create policy "clikes insert self" on public.comment_likes
  for insert with check (auth.uid() = user_id);

drop policy if exists "clikes delete self or admin" on public.comment_likes;
create policy "clikes delete self or admin" on public.comment_likes
  for delete using (auth.uid() = user_id or public.is_admin());

-- 消息：只有本人能看 / 标记已读 / 删除
drop policy if exists "notifications self read" on public.notifications;
create policy "notifications self read" on public.notifications
  for select using (auth.uid() = user_id);

drop policy if exists "notifications self update" on public.notifications;
create policy "notifications self update" on public.notifications
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists "notifications self delete" on public.notifications;
create policy "notifications self delete" on public.notifications
  for delete using (auth.uid() = user_id);

-- 11) 显式授权
grant usage on schema public to anon, authenticated;
grant select on public.posts, public.post_likes, public.post_comments, public.comment_likes to anon, authenticated;
grant insert, delete on public.posts to authenticated;
grant update on public.posts to authenticated;
grant insert, delete on public.post_likes to authenticated;
grant insert, delete on public.post_comments to authenticated;
grant insert, delete on public.comment_likes to authenticated;
grant select, insert, update, delete on public.notifications to authenticated;
grant usage, select on all sequences in schema public to authenticated;

-- 12) 自查
-- select count(*) from public.posts;
-- select id, username, left(content,20), like_count, comment_count, pinned from public.posts order by pinned desc, created_at desc limit 10;
