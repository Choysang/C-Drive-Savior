(() => {
  "use strict";
  const encoded = document.getElementById("report-data").textContent;
  const decoder = document.createElement("textarea");
  decoder.innerHTML = encoded;
  const payload = JSON.parse(decoder.value);
  const scan = payload.scan || payload;
  const summary = payload.summary || {};
  const actions = payload.actions || [];
  const tiers = ["GREEN", "YELLOW", "RED", "MOVE"];
  const tierNames = {GREEN:"可放心清理",YELLOW:"需要确认",RED:"不建议手动处理",MOVE:"适合迁移"};
  const $ = id => document.getElementById(id);
  const text = (tag, value, className) => { const node=document.createElement(tag); node.textContent=value ?? ""; if(className) node.className=className; return node; };
  const bytes = value => value == null ? "未知" : `${(Number(value)/1073741824).toFixed(2)} GB`;
  const table = (caption, headers, rows) => {
    if (!rows.length) return text("div", "无", "empty");
    const scroller=document.createElement("div"); scroller.className="table-wrap";
    const wrap=document.createElement("table"); wrap.appendChild(text("caption",caption));
    const head=document.createElement("thead"), hr=document.createElement("tr"); headers.forEach(h=>hr.appendChild(text("th",h))); head.appendChild(hr); wrap.appendChild(head);
    const body=document.createElement("tbody"); rows.forEach(cells=>{const row=document.createElement("tr");cells.forEach((cell,index)=>{const td=text("td",cell.value,cell.className);if(index===cells.length-2&&cell.code){td.textContent="";td.appendChild(text("code",cell.value));}row.appendChild(td)});body.appendChild(row)});wrap.appendChild(body);scroller.appendChild(wrap);return scroller;
  };
  const drive=(scan.drives||[])[0]||{};
  const currentFree=summary.current_free_bytes ?? drive.free_bytes;
  const metrics=[
    ["总容量",bytes(drive.total_bytes)],
    ["扫描时可用",bytes(drive.free_bytes)],
    ["当前可用",bytes(currentFree)],
    ["磁盘净变化",bytes(summary.net_freed_bytes)],
    ["动作可归因释放",bytes(summary.attributable_freed_bytes)],
    ["差额",bytes(summary.difference_bytes)]
  ];
  metrics.forEach(([key,value])=>{const card=document.createElement("div");card.className="metric";card.append(text("div",key,"k"),text("div",value,"v"));$("disk-metrics").appendChild(card)});
  const total=Number(drive.total_bytes||0), used=Number(drive.used_bytes||0), net=Math.max(0,Number(summary.net_freed_bytes||0));
  const usedPart=text("span","");usedPart.className="used";usedPart.style.width=total?`${Math.min(100,used/total*100)}%`:"0%";
  const freedPart=text("span","");freedPart.className="freed";freedPart.style.width=total?`${Math.min(100,net/total*100)}%`:"0%";$("disk-bar").append(usedPart,freedPart);
  $("subtitle").textContent=`会话 ${payload.session_id||scan.session_id||"-"} · ${payload.generated_at||scan.generated_at||""}`;
  const rows=[...(scan.rows||[])]; const top=[...rows].sort((a,b)=>Number(b.unique_bytes)-Number(a.unique_bytes)).slice(0,5);
  const largest=top[0]; const denied=(scan.denied_paths||[]).length; const incomplete=scan.scan_complete===false;
  $("insight").textContent=summary.net_freed_bytes!=null ? `磁盘净变化 ${bytes(summary.net_freed_bytes)}，其中动作可归因 ${bytes(summary.attributable_freed_bytes)}；差额可能来自扫描期间的系统写入、硬链接或其他进程。` : `${incomplete?"扫描未完整完成；":"扫描已完成；"}${largest?`最大候选为 ${largest.path}（${bytes(largest.unique_bytes)}）。`:"未发现超过阈值的目录。"}${denied?` 有 ${denied} 个路径无法读取。`:""}`;
  const rowCells=r=>[{value:r.tier,className:`tier ${r.tier}`},{value:bytes(r.unique_bytes),className:"num"},{value:r.path,code:true},{value:r.note}];
  $("top-five").appendChild(table("按唯一字节排序",["级别","大小","路径","建议"],top.map(rowCells)));
  const priority=[...rows].sort((a,b)=>tiers.indexOf(a.tier)-tiers.indexOf(b.tier)||Number(b.unique_bytes)-Number(a.unique_bytes)).slice(0,10);
  $("priority").appendChild(table("先低风险，再迁移与人工判断",["级别","大小","路径","建议"],priority.map(rowCells)));
  tiers.forEach(tier=>{const box=document.createElement("div");box.appendChild(text("h3",`${tier} · ${tierNames[tier]}`,`tier ${tier}`));const items=rows.filter(r=>r.tier===tier).sort((a,b)=>Number(b.unique_bytes)-Number(a.unique_bytes));box.appendChild(table(tierNames[tier],["大小","路径","说明"],items.map(r=>[{value:bytes(r.unique_bytes),className:"num"},{value:r.path,code:true},{value:r.note}])));$("tier-sections").appendChild(box)});
  $("denied").appendChild(table("未读取",["路径","错误"],(scan.denied_paths||[]).map(x=>[{value:x.path,code:true},{value:x.error_message}])));
  $("reparse").appendChild(table("未跟随",["路径","类型"],(scan.skipped_reparse_points||[]).map(x=>[{value:x.path,code:true},{value:x.kind||"reparse-point"}])));
  const actionRows=actions.map(a=>[{value:a.status,className:a.status},{value:bytes(a.freed_bytes),className:"num"},{value:a.item_id},{value:a.source||"",code:true},{value:a.error_message||a.undo?.kind||""}]);
  $("actions").appendChild(table("仅当前会话",["状态","释放","项目","来源","结果 / 撤销"],actionRows));
  ["启用 Windows 存储感知并设置回收站保留期。","下载、聊天文件、游戏库和开发缓存优先放到非系统盘。","浏览器和开发缓存会重新增长，定期重新扫描。","迁移后先完成应用冒烟测试，再执行 Finalize。"].forEach(item=>$("maintenance").appendChild(text("li",item)));
})();
