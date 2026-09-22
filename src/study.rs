//! Local study library: annotated move trees, portable PGN and spaced review.
use anyhow::{Context, Result, bail, ensure};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use shakmaty::{CastlingMode, Chess, EnPassantMode, Position, fen::Fen, san::SanPlus, uci::UciMove};
use std::{collections::BTreeMap, path::{Path, PathBuf}};
use crate::game::{Game, now_ms};
const DAY: u64 = 86_400_000;

#[derive(Clone, Serialize, Deserialize, Default)]
pub struct Library {
    version: u32,
    next_id: u64,
    books: Vec<Book>,
    chapters: Vec<Chapter>,
    reviews: Vec<Review>,
    session: Option<Session>,
    sessions: Vec<Session>,
}
#[derive(Clone, Serialize, Deserialize)]
struct Book { id: String, title: String }
#[derive(Clone, Serialize, Deserialize)]
pub struct Chapter {
    pub id: String,
    book: String,
    title: String,
    tags: String,
    side: String,
    pub nodes: Vec<Node>,
    headers: BTreeMap<String,String>,
    bookmark: usize,
    completed: bool,
    revision: u64,
    updated: u64,
}
#[derive(Clone, Serialize, Deserialize)]
pub struct Node {
    pub(crate) parent: Option<usize>,
    children: Vec<usize>,
    pub fen: String,
    uci: String,
    san: String,
    comment: String,
    nags: Vec<String>,
    marks: Vec<String>,
    card: Option<Card>,
}
#[derive(Clone, Serialize, Deserialize)]
struct Card { answers: Vec<String>, due: u64, interval: u64, streak: u32, lapses: u32 }
#[derive(Clone, Serialize, Deserialize)]
struct Review { at: u64, chapter: String, topic: String, grade: String }
#[derive(Clone, Serialize, Deserialize)]
struct Session { started: u64, minutes: u64, items: Vec<Value>, at: usize, ended: Option<u64> }

fn position(fen: &str) -> Result<Chess> {
    if fen.is_empty() || fen == "startpos" { return Ok(Chess::default()); }
    Ok(fen.parse::<Fen>()?.into_position(CastlingMode::Standard)?)
}
fn fen(pos: &Chess) -> String { Fen::from_position(pos, EnPassantMode::Legal).to_string() }
fn root_node(initial: &str) -> Result<Node> {
    Ok(Node { parent: None, children: vec![], fen: fen(&position(initial)?), uci: String::new(), san: String::new(), comment: String::new(), nags: vec![], marks: vec![], card: None })
}
fn new_chapter(initial: &str) -> Result<Chapter> {
    Ok(Chapter { id: String::new(), book: String::new(), title: "Untitled chapter".into(), tags: String::new(), side: "white".into(), nodes: vec![root_node(initial)?], headers: BTreeMap::new(), bookmark: 0, completed: false, revision: 0, updated: now_ms() })
}
fn normalize(pos: &Chess, notation: &str) -> Result<shakmaty::Move> {
    let clean = notation.trim().trim_end_matches(['!','?']).replace("0-0", "O-O");
    if let Ok(uci) = clean.parse::<UciMove>() { return Ok(uci.to_move(pos)?); }
    Ok(clean.parse::<SanPlus>()?.san.to_move(pos)?)
}
impl Chapter {
    fn add(&mut self, parent: usize, notation: &str) -> Result<usize> {
        let mut pos = position(&self.nodes.get(parent).context("Position not found")?.fen)?;
        let mv = normalize(&pos, notation).with_context(|| format!("Invalid move: {notation}"))?;
        let uci = mv.to_uci(CastlingMode::Standard).to_string();
        if let Some(id) = self.nodes[parent].children.iter().find(|id| self.nodes[**id].uci == uci) { return Ok(*id); }
        ensure!(self.nodes.len() < 10000, "Chapter is too large (10,000 positions maximum)");
        let san = SanPlus::from_move(pos.clone(), mv).to_string();
        pos.play_unchecked(mv);
        let id = self.nodes.len();
        self.nodes.push(Node { parent: Some(parent), children: vec![], fen: fen(&pos), uci, san, comment: String::new(), nags: vec![], marks: vec![], card: None });
        self.nodes[parent].children.push(id);
        Ok(id)
    }
    fn summary(&self) -> Value {
        json!({"id":self.id,"book":self.book,"title":self.title,"tags":self.tags,"side":self.side,"bookmark":self.bookmark,"completed":self.completed,"positions":self.nodes.len(),"updated":self.updated,
            "cards":self.nodes.iter().filter(|n| n.card.is_some()).count(), "due":self.nodes.iter().filter(|n| n.card.as_ref().is_some_and(|c| c.due <= now_ms())).count()})
    }
    pub fn export(&self) -> String {
        let escape = |s: &str| s.replace('\\',"\\\\").replace('"',"\\\"").replace(['\n','\r']," ");
        let mut headers = self.headers.clone();
        headers.insert("Event".into(),self.title.clone());
        headers.insert("SetUp".into(),"1".into());
        headers.insert("FEN".into(),self.nodes[0].fen.clone());
        headers.entry("Result".into()).or_insert("*".into());
        let mut out = headers.iter().map(|(k,v)| format!("[{k} \"{}\"]\n",escape(v))).collect::<String>();
        out.push('\n');
        enum Task { Children(usize), Move(usize), Text(&'static str) }
        let mut tasks=vec![Task::Children(0)];
        let comment = |node: &Node| {
            let mut text = node.comment.replace(['{','}']," ");
            for (size, key) in [(5,"cal"),(3,"csl")] {
                let marks: Vec<_> = node.marks.iter().filter(|m|m.len()==size).cloned().collect();
                if !marks.is_empty() { text += &format!(" [%{key} {}]",marks.join(",")); }
            }
            if text.trim().is_empty() { String::new() } else { format!("{{{}}} ",text.trim()) }
        };
        out += &comment(&self.nodes[0]);
        while let Some(task)=tasks.pop() {
            match task {
                Task::Text(text) => out.push_str(text),
                Task::Children(parent) => if let Some(first)=self.nodes[parent].children.first() {
                    tasks.push(Task::Children(*first));
                    for alt in self.nodes[parent].children.iter().skip(1).rev() {
                        tasks.push(Task::Text(") ")); tasks.push(Task::Children(*alt)); tasks.push(Task::Move(*alt)); tasks.push(Task::Text("( "));
                    }
                    tasks.push(Task::Move(*first));
                },
                Task::Move(id) => {
                    let node=&self.nodes[id];
                    let parts: Vec<_>=self.nodes[node.parent.unwrap()].fen.split_whitespace().collect();
                    out += &format!("{}{} {} {}",parts[5],if parts[1]=="w" {"."} else {"..."},node.san, if node.nags.is_empty() {String::new()} else {node.nags.join(" ")+" "});
                    out += &comment(node);
                }
            }
        }
        out += headers["Result"].as_str(); out.push('\n'); out
    }
}

#[derive(Debug)]
enum Token { Tag(String,String), Word(String), Comment(String), Open, Close }
fn tokens(pgn: &str) -> Result<Vec<Token>> {
    ensure!(pgn.len() <= 5_000_000,"PGN exceeds 5 MB");
    let mut chars=pgn.trim_start_matches('\u{feff}').chars().peekable(); let mut out=vec![];
    while let Some(c)=chars.next() {
        match c {
            c if c.is_whitespace() => {},
            ';' | '%' => { for c in chars.by_ref() {if c=='\n' {break}} },
            '{' => { let mut text=String::new(); let mut closed=false; for c in chars.by_ref() {if c=='}' {closed=true;break} text.push(c)} ensure!(closed,"Unclosed PGN comment"); out.push(Token::Comment(text)); },
            '(' => out.push(Token::Open), ')' => out.push(Token::Close),
            '[' => {
                let mut name=String::new(); while chars.peek().is_some_and(|c|c.is_whitespace()) {chars.next();}
                while let Some(c)=chars.peek().copied() {if c.is_whitespace() || c=='"' {break} name.push(c);chars.next();}
                ensure!(!name.is_empty() && name.chars().all(|c|c.is_ascii_alphanumeric() || c=='_'),"Invalid PGN tag");
                while chars.peek().is_some_and(|c|c.is_whitespace()) {chars.next();}
                ensure!(chars.next()==Some('"'),"Missing PGN tag value");
                let mut value=String::new(); let mut closed=false;
                while let Some(c)=chars.next() { if c=='"' {closed=true;break} else if c=='\\' {value.push(chars.next().context("Invalid PGN escape")?)} else {value.push(c)} }
                ensure!(closed,"Unclosed PGN tag"); while chars.peek().is_some_and(|c|c.is_whitespace()) {chars.next();}
                ensure!(chars.next()==Some(']'),"Unclosed PGN tag"); out.push(Token::Tag(name,value));
            },
            _ => { let mut word=c.to_string(); while let Some(c)=chars.peek().copied() {if c.is_whitespace() || "{}()[];".contains(c) {break} word.push(c);chars.next();} out.push(Token::Word(word)); }
        }
    }
    Ok(out)
}
fn apply_comment(node: &mut Node, comment: &str) {
    let mut text=comment.to_owned();
    for key in ["cal","csl"] {
        let start=format!("[%{key} ");
        while let Some(at)=text.find(&start) {
            let Some(end)=text[at..].find(']') else {break};
            let value=&text[at+start.len()..at+end];
            for mark in value.split(',') {if valid_mark(mark.trim()) {node.marks.push(mark.trim().into());}}
            text.replace_range(at..=at+end,"");
        }
    }
    if !node.comment.is_empty() && !text.trim().is_empty() {node.comment.push('\n');} node.comment.push_str(text.trim());
}
fn valid_mark(mark: &str) -> bool {
    let b=mark.as_bytes();
    matches!(b.len(),3|5) && b"GRYB".contains(&b[0]) && b"abcdefgh".contains(&b[1]) && b"12345678".contains(&b[2]) && (b.len()==3 || (b"abcdefgh".contains(&b[3]) && b"12345678".contains(&b[4])))
}
pub fn parse_pgn(pgn: &str) -> Result<Vec<Chapter>> {
    let mut chapters=vec![]; let mut ch=new_chapter("startpos")?; let mut at=0; let mut stack=vec![]; let mut ended=false; let mut moves=false;
    for token in tokens(pgn)? {
        if (ended && !matches!(token,Token::Comment(_))) || (moves && stack.is_empty() && matches!(token,Token::Tag(_, _))) {
            ensure!(stack.is_empty(),"Unclosed PGN variation"); chapters.push(ch); ch=new_chapter("startpos")?; at=0; ended=false; moves=false;
            ensure!(chapters.len()<500,"Import at most 500 games at a time");
        }
        match token {
            Token::Tag(key,value) => {
                ensure!(!moves,"PGN tag inside movetext");
                if key=="Variant" {ensure!(matches!(value.as_str(),"Standard"|"From Position"),"Only standard chess studies are supported");}
                if key=="FEN" {ch.nodes[0]=root_node(&value)?;}
                if key=="Event" {ch.title=value.clone();}
                ch.headers.insert(key,value);
            },
            Token::Comment(text) => apply_comment(&mut ch.nodes[at],&text),
            Token::Open => { ensure!(stack.len()<128,"Too many nested variations"); stack.push(at); at=ch.nodes[at].parent.context("Variation has no preceding move")?; },
            Token::Close => {at=stack.pop().context("Unexpected variation end")?;},
            Token::Word(word) => {
                if matches!(word.as_str(),"*"|"1-0"|"0-1"|"1/2-1/2") { if stack.is_empty(){ch.headers.insert("Result".into(),word); ended=true;} continue; }
                let san=if word.starts_with("0-0") {word.as_str()} else {word.trim_start_matches(|c:char| c.is_ascii_digit() || c=='.')};
                if let Some(annotation) = word.strip_prefix('$') {ensure!(annotation.parse::<u16>().is_ok(),"Invalid annotation");ch.nodes[at].nags.push(word);continue;}
                if matches!(word.as_str(),"!"|"?"|"!!"|"??"|"!?"|"?!") {ch.nodes[at].nags.push(word);continue;}
                if san.is_empty() {continue;}
                at=ch.add(at,san)?; moves=true;
                let nag=san.trim_start_matches(|c| c!='!' && c!='?'); if !nag.is_empty() {ch.nodes[at].nags.push(nag.into());}
            }
        }
    }
    ensure!(stack.is_empty(),"Unclosed PGN variation");
    if moves || !ch.headers.is_empty() || !ch.nodes[0].comment.is_empty() {chapters.push(ch);}
    ensure!(!chapters.is_empty(),"No games found in PGN");
    for ch in &mut chapters {
        if let (Some(w),Some(b))=(ch.headers.get("White"),ch.headers.get("Black")) {ch.title=format!("{w} × {b} · {}",ch.title);}
    }
    Ok(chapters)
}
fn text(req: &Value,key: &str,max: usize) -> Result<String> {
    let value=req[key].as_str().unwrap_or("").trim(); ensure!(value.len()<=max,"{key} is too long"); Ok(value.into())
}
fn file_path(value: &str) -> Result<PathBuf> {
    let path=if value.starts_with("file:") {reqwest::Url::parse(value)?.to_file_path().map_err(|_|anyhow::anyhow!("Choose a local file"))?} else {PathBuf::from(value)};
    ensure!(path.extension().is_some_and(|s|s.eq_ignore_ascii_case("pgn")),"Choose a .pgn file"); Ok(path)
}
impl Library {
    pub fn load(path: &Path) -> Result<Self> {
        if !path.exists() {return Ok(Self {version:1,next_id:1,..Self::default()});}
        let result: Self=serde_json::from_slice(&std::fs::read(path)?).context("Invalid studies file; kept for recovery")?;
        ensure!(result.version==1,"Unsupported studies version");
        for ch in &result.chapters {
            ensure!(!ch.nodes.is_empty() && ch.bookmark<ch.nodes.len(),"Invalid saved study");
            for (id,node) in ch.nodes.iter().enumerate() {
                position(&node.fen)?;
                ensure!(node.parent.is_none_or(|p|p<id) && node.children.iter().all(|c|*c>id && *c<ch.nodes.len() && ch.nodes[*c].parent==Some(id)),"Invalid study tree");
            }
        }
        Ok(result)
    }
    pub fn save(&self,path: &Path) -> Result<()> {
        crate::private_dir(path.parent().context("Missing study folder")?)?;
        let tmp=path.with_extension("tmp"); std::fs::write(&tmp,serde_json::to_vec(self)?)?; std::fs::rename(tmp,path)?; Ok(())
    }
    fn id(&mut self,prefix: &str) -> String {let id=format!("{prefix}-{}",self.next_id);self.next_id+=1;id}
    fn book(&mut self,title: &str) -> String { let id=self.id("book"); self.books.push(Book {id:id.clone(),title:title.into()});id }
    fn add_chapter(&mut self,mut ch: Chapter,book: &str) -> Result<String> {
        ensure!(self.books.iter().any(|b|b.id==book),"Notebook not found");
        ch.id=self.id("chapter");ch.book=book.into();let id=ch.id.clone();self.chapters.push(ch);Ok(id)
    }
    pub fn chapter(&self,id: &str) -> Result<&Chapter> {self.chapters.iter().find(|c|c.id==id).context("Chapter not found")}
    fn chapter_mut(&mut self,req: &Value) -> Result<&mut Chapter> {
        let ch=self.chapters.iter_mut().find(|c|Some(c.id.as_str())==req["chapter"].as_str()).context("Chapter not found")?;
        if let Some(revision)=req["revision"].as_u64() {ensure!(revision==ch.revision,"Chapter changed in another window. Refresh before editing.");}
        Ok(ch)
    }
    fn overview(&self) -> Value {
        let now=now_ms();let mut due=vec![];
        for ch in &self.chapters {for (node,n) in ch.nodes.iter().enumerate() {if let Some(card)=&n.card && card.due<=now {due.push(json!({"chapter":ch.id,"node":node,"title":ch.title,"topic":ch.tags,"due":card.due,"lapses":card.lapses,"mode":"review"}));}}}
        due.sort_by_key(|v|v["due"].as_u64());
        let mut topics:BTreeMap<String,(usize,usize)>=BTreeMap::new();
        for r in &self.reviews {let t=topics.entry(r.topic.clone()).or_default();t.1+=1;if r.grade=="again" {t.0+=1;}}
        json!({"books":self.books,"chapters":self.chapters.iter().map(Chapter::summary).collect::<Vec<_>>(),"due":due,"session":self.session,
            "stats":{"reviews":self.reviews.len(),"today":self.reviews.iter().filter(|r|now.saturating_sub(r.at)<DAY).count(),"sessions":self.sessions.len(),"topics":topics.into_iter().map(|(topic,(again,total))|json!({"topic":topic,"again":again,"total":total})).collect::<Vec<_>>()}})
    }
    pub fn capture(&mut self,game: &Game,ply: usize,book: &str) -> Result<Value> {
        let book=if book.is_empty() {if let Some(b)=self.books.iter().find(|b|b.title=="My games") {b.id.clone()} else {self.book("My games")}} else {book.into()};
        let mut ch=parse_pgn(&game.pgn()?)?.remove(0); ch.title=format!("{} × {}",game.white,game.black);ch.tags="My games".into();ch.bookmark=ply.min(game.moves.len());
        ch.side=game.color.clone().unwrap_or("white".into());
        if let Some(analysis)=&game.lichess_analysis && let Some(entries)=analysis["moves"].as_array() {
            for (ply,entry) in entries.iter().enumerate().take(game.moves.len()) {
                if entry["judgment"].is_null() {continue;}
                ch.nodes[ply].comment=entry["judgment"]["comment"].as_str().unwrap_or("Find an improvement.").into();
                let mut at=ply;
                if let Some(line)=entry["variation"].as_str() {
                    for notation in line.split_whitespace() {match ch.add(at,notation) {Ok(next)=>at=next,Err(_)=>break}}
                }
                if let Some(best)=entry["best"].as_str() && let Ok(next)=ch.add(ply,best) {
                    ch.nodes[ply].card=Some(Card {answers:vec![ch.nodes[next].uci.clone()],due:now_ms(),interval:0,streak:0,lapses:0});
                }
            }
        }
        let id=self.add_chapter(ch,&book)?;Ok(json!({"chapter":self.chapter(&id)?,"library":self.overview()}))
    }
    pub fn handle(&mut self,req: &Value) -> Result<Value> {
        let cmd=req["cmd"].as_str().unwrap_or("");let chapter=req["chapter"].as_str().unwrap_or(""); let node=req["node"].as_u64().unwrap_or(0) as usize;
        match cmd {
            "study_list" => return Ok(json!({"library":self.overview()})),
            "study_get" => return Ok(json!({"chapter":self.chapter(chapter)?})),
            "study_create" => {let title=text(req,"title",160)?;ensure!(!title.is_empty(),"Name your notebook");let id=self.book(&title);return Ok(json!({"book":id,"library":self.overview()}));},
            "study_rename_book" => {let title=text(req,"title",160)?;ensure!(!title.is_empty(),"Name your notebook");self.books.iter_mut().find(|b|Some(b.id.as_str())==req["book"].as_str()).context("Notebook not found")?.title=title;},
            "study_chapter" => {let mut ch=new_chapter(req["fen"].as_str().unwrap_or("startpos"))?;let title=text(req,"title",160)?;ensure!(!title.is_empty(),"Name your chapter");ch.title=title;let id=self.add_chapter(ch,req["book"].as_str().unwrap_or(""))?;return Ok(json!({"chapter":self.chapter(&id)?,"library":self.overview()}));},
            "study_import" => {
                let pgn=if let Some(path)=req["path"].as_str() {let path=file_path(path)?;ensure!(std::fs::metadata(&path)?.len()<=5_000_000,"PGN exceeds 5 MB");std::fs::read_to_string(path)?} else {text(req,"pgn",5_000_000)?};
                let imported=parse_pgn(&pgn)?;let count=imported.len();let mut last=String::new();
                for ch in imported {last=self.add_chapter(ch,req["book"].as_str().context("Choose a notebook")?)?;}
                return Ok(json!({"chapter":self.chapter(&last)?,"imported":count,"library":self.overview()}));
            },
            "study_export" => {
                let pgn=if chapter.is_empty() {let book=req["book"].as_str().context("Choose a notebook")?;self.chapters.iter().filter(|c|c.book==book).map(Chapter::export).collect::<Vec<_>>().join("\n")} else {self.chapter(chapter)?.export()};
                ensure!(!pgn.is_empty(),"No chapters to export");
                if let Some(path)=req["path"].as_str() {let path=file_path(path)?;std::fs::write(&path,&pgn)?;return Ok(json!({"message":"PGN exported"}));}
                return Ok(json!({"pgn":pgn}));
            },
            "study_delete" => {ensure!(req["confirm"]==true,"Confirm deletion");self.chapter(chapter)?;self.chapters.retain(|c|c.id!=chapter);if let Some(session)=&mut self.session {session.items.retain(|i|i["chapter"]!=chapter);session.at=session.at.min(session.items.len());}},
            "study_bookmark" => {let ch=self.chapter_mut(req)?;ensure!(node<ch.nodes.len(),"Position not found");ch.bookmark=node;return Ok(json!({"saved":true}));},
            "study_move" => {let ch=self.chapter_mut(req)?;let at=ch.add(node,req["notation"].as_str().context("Enter a move")?)?;ch.bookmark=at;ch.revision+=1;ch.updated=now_ms();return Ok(json!({"chapter":ch,"node":at}));},
            "study_edit" => {
                let ch=self.chapter_mut(req)?;ensure!(node<ch.nodes.len(),"Position not found");
                if req.get("comment").is_some() {ch.nodes[node].comment=text(req,"comment",20000)?;}
                if req.get("title").is_some() {let title=text(req,"title",160)?;ensure!(!title.is_empty(),"Name your chapter");ch.title=title;}
                if req.get("tags").is_some() {ch.tags=text(req,"tags",300)?;}
                if let Some(side)=req["side"].as_str() {ensure!(matches!(side,"white"|"black"|"both"),"Choose a training side");ch.side=side.into();}
                if let Some(value)=req["completed"].as_bool() {ch.completed=value;}
                if let Some(marks)=req["marks"].as_array() {ensure!(marks.len()<=64,"Too many board marks");let marks:Vec<_>=marks.iter().map(|m|m.as_str().unwrap_or("").to_owned()).collect();ensure!(marks.iter().all(|m|valid_mark(m)),"Invalid board annotation");ch.nodes[node].marks=marks;}
                ch.revision+=1;ch.updated=now_ms();return Ok(json!({"chapter":ch,"node":node}));
            },
            "study_card" => {
                let ch=self.chapter_mut(req)?;ensure!(node<ch.nodes.len(),"Position not found");
                if req["enabled"]==false {ch.nodes[node].card=None;} else {
                    let answer=if let Some(notation)=req["answer"].as_str().filter(|s|!s.trim().is_empty()) {let child=ch.add(node,notation)?;ch.nodes[child].uci.clone()} else {let first=*ch.nodes[node].children.first().context("Add a solution move first, or enter it below")?;ch.nodes[first].uci.clone()};
                    ch.nodes[node].card=Some(Card {answers:vec![answer],due:now_ms(),interval:0,streak:0,lapses:0});
                }
                ch.revision+=1;return Ok(json!({"chapter":ch,"node":node}));
            },
            "study_try" => {
                let ch=self.chapter(chapter)?;let current=ch.nodes.get(node).context("Position not found")?;
                let pos=position(&current.fen)?;let mv=normalize(&pos,req["notation"].as_str().context("Enter a move")?)?;let uci=mv.to_uci(CastlingMode::Standard).to_string();
                let answers=if req["mode"]=="review" {current.card.as_ref().context("This position is not a review card")?.answers.clone()} else {current.children.iter().map(|id|ch.nodes[*id].uci.clone()).collect()};
                ensure!(!answers.is_empty(),"End of the stored line");let correct=answers.contains(&uci);
                let next=current.children.iter().find(|id|ch.nodes[**id].uci==uci).copied();
                return Ok(json!({"correct":correct,"node":if correct {next} else {None},"message":if correct {"Matches the stored line."} else {"Different from the stored line. Try again or reveal it; this does not necessarily mean your move is bad."}}));
            },
            "study_grade" => {
                let grade=req["grade"].as_str().context("Choose a review result")?;ensure!(matches!(grade,"again"|"hard"|"good"|"easy"),"Invalid review result");
                let ch=self.chapter_mut(req)?;let card=ch.nodes.get_mut(node).and_then(|n|n.card.as_mut()).context("Review card not found")?;
                if let Some(due)=req["due"].as_u64() {ensure!(due==card.due,"This review was already recorded. Refresh the queue.");}
                match grade {
                    "again" => {card.streak=0;card.lapses+=1;card.interval=600_000;},
                    "hard" => {card.streak+=1;card.interval=DAY.max(card.interval);},
                    "good" => {card.streak+=1;card.interval=if card.interval<DAY {DAY} else {card.interval.saturating_mul(2).min(180*DAY)};},
                    _ => {card.streak+=1;card.interval=if card.interval<DAY {3*DAY} else {card.interval.saturating_mul(3).min(365*DAY)};}
                }
                card.due=now_ms()+card.interval;ch.revision+=1;
                let review=Review {at:now_ms(),chapter:ch.id.clone(),topic:if ch.tags.is_empty(){"Unsorted".into()}else{ch.tags.clone()},grade:grade.into()};
                self.reviews.push(review);if self.reviews.len()>2000 {self.reviews.remove(0);}
                return Ok(json!({"chapter":self.chapter(chapter)?,"node":node,"library":self.overview()}));
            },
            "study_session_start" => {
                ensure!(self.session.is_none(),"Resume or finish your current session first");
                let overview=self.overview();let mut items=overview["due"].as_array().unwrap().iter().take(10).cloned().collect::<Vec<_>>();
                for ch in self.chapters.iter().filter(|c|!c.completed && c.nodes.len()>1).take(2) {items.push(json!({"chapter":ch.id,"node":ch.bookmark,"title":ch.title,"mode":"guess"}));}
                ensure!(!items.is_empty(),"Add a chapter or a review card first");
                self.session=Some(Session {started:now_ms(),minutes:req["minutes"].as_u64().unwrap_or(20).clamp(5,120),items,at:0,ended:None});
            },
            "study_session_next" => {let s=self.session.as_mut().context("No active session")?;s.at=(s.at+1).min(s.items.len());},
            "study_session_end" => {let mut s=self.session.take().context("No active session")?;s.ended=Some(now_ms());self.sessions.push(s);if self.sessions.len()>100 {self.sessions.remove(0);}},
            "study_examples" => {
                let book=self.book("Getting started");
                let examples="[Event \"Italian game: development\"]\n\n{Occupy the centre, develop pieces and castle. Train this chapter as White, then try Black.} 1. e4 {Control d5 and free the bishop.} e5 2. Nf3 {Develop with a threat against e5.} Nc6 3. Bc4 {Aim at f7.} (3. Bb5 {The Spanish is another plan.} a6 4. Ba4) Bc5 4. c3 {Prepare d4.} Nf6 5. d3 d6 6. O-O *\n\n[Event \"Back-rank mate\"]\n[SetUp \"1\"]\n[FEN \"6k1/5ppp/8/8/8/8/5PPP/4R1K1 w - - 0 1\"]\n\n{Find a forcing move. What squares can the black king use?} 1. Re8# {The pawns block the escape squares. [%cal Ge1e8] [%csl Gf7,Gg7,Gh7]} 1-0\n\n[Event \"Opposition and promotion\"]\n[SetUp \"1\"]\n[FEN \"8/4k3/8/4K3/4P3/8/8/8 w - - 0 1\"]\n\n{Explore king moves, then compare your plan with the engine. This is a sandbox, not a forced winning line.} *";
                for mut ch in parse_pgn(examples)? {if ch.title.contains("Back-rank") {ch.nodes[0].card=Some(Card {answers:vec!["e1e8".into()],due:now_ms(),interval:0,streak:0,lapses:0});ch.tags="Mate patterns".into();} self.add_chapter(ch,&book)?;}
            },
            _ => bail!("Unknown study command"),
        }
        Ok(json!({"library":self.overview()}))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_comments_variations_and_marks() {
        let chapters = parse_pgn("[Event \"Italian\"]\n[White \"A\"]\n[Black \"B\"]\n\n{Plan} 1. e4 $1 {[%cal Ge2e4] [%csl Rf7]} e5 (1... c5) 2. Nf3 *").unwrap();
        let chapter = &chapters[0];
        assert_eq!(chapter.nodes.len(), 5);
        assert_eq!(chapter.nodes[1].san, "e4");
        assert_eq!(chapter.nodes[1].nags, vec!["$1"]);
        assert_eq!(chapter.nodes[1].marks, vec!["Ge2e4", "Rf7"]);
        assert_eq!(chapter.nodes[1].children.len(), 2);
        assert!(chapter.nodes[0].comment.contains("Plan"));
    }

    #[test]
    fn review_cards_are_due_and_grade_changes_interval() {
        let mut library = Library::default();
        let book = library.book("Notebook");
        let mut chapter = new_chapter("startpos").unwrap();
        chapter.title = "Italian".into();
        chapter.add(0, "e4").unwrap();
        let id = library.add_chapter(chapter, &book).unwrap();
        let response = library.handle(&json!({"cmd":"study_card","chapter":id,"node":0,"enabled":true,"revision":0})).unwrap();
        assert_eq!(response["node"], 0);
        let overview = library.overview();
        let due = overview["due"].as_array().unwrap();
        assert_eq!(due.len(), 1);
        library.handle(&json!({"cmd":"study_grade","chapter":id,"node":0,"grade":"good","due":due[0]["due"],"revision":1})).unwrap();
        assert!(library.overview()["due"].as_array().unwrap().is_empty());
    }

    #[test]
    fn export_round_trip_keeps_variation() {
        let chapter = parse_pgn("[Event \"Round trip\"]\n\n1. e4 e5 (1... c5) 2. Nf3 *").unwrap().remove(0);
        let exported = chapter.export();
        let imported = parse_pgn(&exported).unwrap();
        assert!(imported[0].nodes.iter().any(|node| node.san == "e4"));
        assert!(imported[0].nodes.iter().any(|node| node.san == "c5"));
    }
}
