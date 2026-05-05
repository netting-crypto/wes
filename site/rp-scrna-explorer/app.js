(function () {
  const data = window.SCRNA_EXPLORER_DATA;
  if (!data) {
    throw new Error("SCRNA_EXPLORER_DATA 缺失");
  }

  const state = {
    section: "overview",
    sortKey: "best_total_priority_score",
    search: "",
    selectedGene: data.allGenes[0]?.gene || "",
    selectedVariant: data.topVariants[0]?.variant || "",
    selectedModule: data.modules[0]?.module_id || "",
    umapFilter: "all",
  };

  const LABELS = {
    rod: "杆细胞",
    cone: "锥细胞",
    bipolar: "双极细胞",
    amacrine: "无长突细胞",
    muller: "Muller 胶质",
    microglia: "小胶质细胞",
    rgc: "神经节细胞",
    horizontal: "水平细胞",
    astrocyte: "星形胶质",
    photoreceptor: "光感受器",
    PanelApp: "PanelApp",
    downloaded: "已纳入",
    ready: "可用",
  };

  const MODEL_KEYS = [
    { key: "rpgr", label: "RPGR 类器官" },
    { key: "rd1", label: "rd1 小鼠" },
    { key: "rd10", label: "rd10 小鼠" },
  ];

  const DATASET_LABELS = {
    rd10_retina_gse183206: "rd10 小鼠 P21 视网膜",
    rd1_retina_gse212183: "rd1 小鼠 P11/P13/P17 视网膜",
    rpgr_organoid_srp535874: "RPGR 突变视网膜类器官",
    normal_human_retina_lukowski_zenodo: "正常成人视网膜单细胞",
  };

  const SCORE_COLORS = {
    best_normal_celltype_score: ["#eff6ff", "#3c7cff"],
    best_disease_model_score: ["#fff1ea", "#ff8d6a"],
    best_network_support_score: ["#ecfbf4", "#5ac1a8"],
    best_total_priority_score: ["#eef2ff", "#7a66ff"],
  };

  const $ = (selector) => document.querySelector(selector);
  const $$ = (selector) => Array.from(document.querySelectorAll(selector));

  function fmt(value, digits = 0) {
    if (value === null || value === undefined || value === "") return "—";
    if (typeof value === "number") return digits > 0 ? value.toFixed(digits) : String(value);
    return String(value);
  }

  function toList(value) {
    if (!value) return [];
    if (Array.isArray(value)) return value.filter(Boolean);
    return String(value).split(";").filter(Boolean);
  }

  function zh(value) {
    return LABELS[value] || value;
  }

  function esc(text) {
    return String(text ?? "")
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;")
      .replaceAll('"', "&quot;");
  }

  function chipList(items, cls = "chip") {
    return toList(items).map((item) => `<span class="${cls}">${esc(zh(item.replaceAll("_", " ")))}</span>`).join("");
  }

  function geneSummaryZh(gene) {
    const cellTypes = toList(gene.normal_celltype_expression_support).map(zh).join("、") || "未标出";
    const models = toList(gene.module_network_disease_models).map(zh).join("、") || "暂无";
    const moduleName = gene.coexpression_module_support || "无";
    const moduleType = zh(gene.coexpression_module_celltype_support || "");
    const mechanism = zh(gene.state_module_support || "未分类");
    return `${gene.gene} 当前主要得到 ${cellTypes} 的正常表达支持，位于 ${moduleName}${moduleType ? `（${moduleType}）` : ""}，并在 ${models} 中观察到疾病扰动；机制标签主要落在 ${mechanism}。`;
  }

  function variantSummaryZh(variant) {
    const models = toList(variant.disease_model_support).map(zh).join("、") || "暂无";
    return `${variant.gene} 变异 ${variant.variant} 来自 ${variant.family_id}，当前单细胞支持主要来自 ${models}，综合优先级为 ${fmt(variant.total_priority_score)}。`;
  }

  function workflowCopy(step) {
    const mapping = {
      "step-01": ["数据接入", "纳入正常人视网膜、RPGR 类器官、rd1、rd10 四类 processed 数据，并统一整理成站点可用的结构化结果。"],
      "step-02": ["正常细胞类型评分", "用正常人视网膜数据评估候选基因在 rod、cone、Muller、RGC 等关键细胞类型中的表达支持。"],
      "step-03": ["疾病扰动评分", "汇总 RPGR、rd1、rd10 的 group / time / stage / cell-type 层面的扰动证据。"],
      "step-04": ["网络支持评分", "从正常视网膜抽取共表达模块，再把疾病模型扰动投影回模块层，得到网络支持评分。"],
      "step-05": ["优先级排序", "整合三评分后输出基因级和变异级优先级结果，用于浏览、汇报和后续实验筛选。"],
    };
    return mapping[step.id] || [step.title, step.summary];
  }

  function metricCard(label, value, detail) {
    return `
      <article class="metric-card">
        <div class="metric-value">${esc(value)}</div>
        <div class="metric-label">${esc(label)}</div>
        <div class="muted">${esc(detail)}</div>
      </article>
    `;
  }

  function scoreGradient(start, end, t) {
    const parse = (hex) => {
      const clean = hex.replace("#", "");
      return [0, 2, 4].map((idx) => parseInt(clean.slice(idx, idx + 2), 16));
    };
    const [r1, g1, b1] = parse(start);
    const [r2, g2, b2] = parse(end);
    const mix = (a, b) => Math.round(a + (b - a) * t);
    return `rgb(${mix(r1, r2)}, ${mix(g1, g2)}, ${mix(b1, b2)})`;
  }

  function filteredGenes() {
    const query = state.search.trim().toLowerCase();
    const genes = [...data.allGenes].sort((a, b) => (b[state.sortKey] || 0) - (a[state.sortKey] || 0));
    if (!query) return genes;
    return genes.filter((row) =>
      row.gene.toLowerCase().includes(query) ||
      String(row.top_interpretation || "").toLowerCase().includes(query) ||
      String(row.coexpression_module_support || "").toLowerCase().includes(query)
    );
  }

  function renderMetrics() {
    const overview = data.overview;
    $("#overview-metrics").innerHTML = [
      metricCard("候选变异", overview.candidate_rows, "来自 WES 候选表"),
      metricCard("候选基因", overview.ranked_genes, "完成单细胞证据整合"),
      metricCard("数据集", overview.dataset_count, "正常视网膜 + 3 个疾病模型"),
      metricCard("网络模块", overview.module_count, "正常视网膜共表达模块"),
      metricCard("当前首位基因", overview.top_gene, "综合优先级最高"),
      metricCard("主模块大小", overview.photoreceptor_module_size, "normal_module_01 基因数"),
    ].join("");
  }

  function renderHeroNetwork() {
    const svg = $("#hero-network");
    const topGenes = data.topGenes.slice(0, 7);
    const centerX = 260;
    const centerY = 210;
    const radius = 118;
    const nodes = topGenes.map((row, idx) => {
      const angle = (Math.PI * 2 * idx) / topGenes.length - Math.PI / 2;
      return {
        gene: row.gene,
        x: centerX + Math.cos(angle) * radius,
        y: centerY + Math.sin(angle) * radius,
        score: row.best_total_priority_score,
      };
    });
    const lines = nodes
      .map((node) => `<line x1="${centerX}" y1="${centerY}" x2="${node.x}" y2="${node.y}" stroke="rgba(60,124,255,0.16)" stroke-width="1.2" />`)
      .join("");
    const labels = nodes
      .map((node) => `
        <g>
          <circle cx="${node.x}" cy="${node.y}" r="6" fill="#3c7cff"></circle>
          <text x="${node.x + 10}" y="${node.y + 4}" class="axis-label">${esc(node.gene)}</text>
        </g>
      `)
      .join("");
    svg.innerHTML = `
      <defs>
        <radialGradient id="heroGlow" cx="50%" cy="50%" r="50%">
          <stop offset="0%" stop-color="rgba(60,124,255,0.28)" />
          <stop offset="100%" stop-color="rgba(60,124,255,0)" />
        </radialGradient>
      </defs>
      <rect x="0" y="0" width="520" height="420" fill="transparent"></rect>
      <circle cx="${centerX}" cy="${centerY}" r="148" fill="url(#heroGlow)"></circle>
      <circle cx="${centerX}" cy="${centerY}" r="136" fill="none" stroke="rgba(60,124,255,0.24)" stroke-width="2"></circle>
      <circle cx="${centerX}" cy="${centerY}" r="188" fill="none" stroke="rgba(17,17,17,0.08)" stroke-dasharray="4 5"></circle>
      ${lines}
      <circle cx="${centerX}" cy="${centerY}" r="42" fill="url(#heroCore)"></circle>
      <defs>
        <linearGradient id="heroCore" x1="0%" y1="0%" x2="100%" y2="100%">
          <stop offset="0%" stop-color="#3c7cff" />
          <stop offset="100%" stop-color="#65c7f7" />
        </linearGradient>
      </defs>
      ${labels}
      <g>
        <rect x="48" y="42" rx="20" ry="20" width="122" height="38" fill="rgba(255,255,255,0.88)" />
        <text x="72" y="66" class="axis-label">UMAP → 网络层</text>
      </g>
      <g>
        <rect x="340" y="300" rx="20" ry="20" width="126" height="38" fill="rgba(255,255,255,0.88)" />
        <text x="364" y="324" class="axis-label">疾病证据叠加</text>
      </g>
      <text x="${centerX}" y="${centerY + 84}" text-anchor="middle" class="chart-title">光感受器核心模块</text>
    `;
  }

  function renderDatasets() {
    $("#dataset-list").innerHTML = data.datasets.map((dataset) => `
      <div class="dataset-item">
        <div class="panel-head">
          <h5>${esc(dataset.dataset_id)}</h5>
          <span class="pill">${esc(zh(dataset.status || dataset.download_status || "ready"))}</span>
        </div>
        <p class="muted">${esc(DATASET_LABELS[dataset.dataset_id] || dataset.model)}</p>
        <div class="mini-meta">
          <span class="chip">${fmt(dataset.gene_entries)} 个 gene entries</span>
          <span class="chip">${fmt(dataset.file_count)} 个文件</span>
          <span class="chip">${esc(dataset.accession)}</span>
        </div>
      </div>
    `).join("");
  }

  function renderKeyFindings() {
    const findings = [
      "normal_module_01 以 photoreceptor 为主导，携带 45 个公共 RP/IRD 基因，是当前网络层最核心的证据模块。",
      "ABCA4、RDH12、USH2A 在正常表达、疾病扰动和网络支持三个层面都保持高分，仍然是当前第一梯队。",
      "rd1、rd10 和 RPGR 三类疾病模型不再是孤立证据，而是在同一批候选基因上形成交叉支持。",
      "当前网站与 PPT 导出使用的是同一份本地结果资产，因此浏览界面与汇报结论之间没有版本偏差。",
    ];
    $("#key-findings").innerHTML = findings.map((text, index) => `
      <div class="finding-item">
        <h5>结论 ${index + 1}</h5>
        <p class="muted">${esc(text)}</p>
      </div>
    `).join("");
  }

  function renderTopGeneChart() {
    const top = data.topGenes.slice(0, 12);
    const max = data.scoreRanges.total || 1;
    const selected = state.selectedGene;
    $("#top-gene-chart").innerHTML = top.map((row) => {
      const width = ((row.best_total_priority_score || 0) / max) * 100;
      return `
        <div class="bar-row ${selected && selected !== row.gene ? "is-dim" : ""}">
          <div class="bar-label">${esc(row.gene)}</div>
          <div class="bar-track"><div class="bar-fill" style="width:${width}%"></div></div>
          <div>${fmt(row.best_total_priority_score)}</div>
        </div>
      `;
    }).join("");
  }

  function renderUmap() {
    const svg = $("#umap-plot");
    const summary = $("#umap-summary");
    const legend = $("#umap-legend");
    const umap = data.umap;
    if (!umap || !Array.isArray(umap.points) || !umap.points.length) {
      svg.innerHTML = "";
      summary.innerHTML = "<p class='muted'>暂无 UMAP 数据。</p>";
      legend.innerHTML = "";
      return;
    }

    const points = umap.points;
    const xs = points.map((point) => point.x);
    const ys = points.map((point) => point.y);
    const minX = Math.min(...xs);
    const maxX = Math.max(...xs);
    const minY = Math.min(...ys);
    const maxY = Math.max(...ys);
    const pad = 40;
    const width = 1000;
    const height = 680;
    const sx = (value) => pad + ((value - minX) / Math.max(maxX - minX, 0.001)) * (width - pad * 2);
    const sy = (value) => height - pad - ((value - minY) / Math.max(maxY - minY, 0.001)) * (height - pad * 2);
    const visible = state.umapFilter === "all" ? points : points.filter((point) => point.cellType === state.umapFilter);

    svg.innerHTML = [
      `<rect x="0" y="0" width="${width}" height="${height}" fill="transparent"></rect>`,
      ...points.map((point) => {
        const active = state.umapFilter === "all" || point.cellType === state.umapFilter;
        return `<circle cx="${sx(point.x).toFixed(2)}" cy="${sy(point.y).toFixed(2)}" r="${active ? 2.4 : 1.4}" fill="${point.color}" fill-opacity="${active ? 0.82 : 0.08}" />`;
      }),
    ].join("");

    const counts = Object.entries(umap.celltypeCounts || {}).sort((a, b) => b[1] - a[1]);
    const selectedLabel = state.umapFilter === "all" ? "全部细胞类型" : zh(state.umapFilter);
    summary.innerHTML = `
      <p class="eyebrow">embedding 摘要</p>
      <h5 style="margin:0 0 10px;font-size:22px;">${esc(selectedLabel)}</h5>
      <p class="muted">从 Lukowski 正常人视网膜矩阵中抽样 ${fmt(umap.sampledCellCount)} 个细胞，用 ${fmt(umap.featureGeneCount)} 个高变基因完成 PCA + UMAP 投影。</p>
      <div class="chip-row">
        <span class="chip">${esc(umap.source)}</span>
        <span class="chip">${fmt(visible.length)} 个可见点</span>
        <span class="chip">${fmt(counts.length)} 类细胞</span>
      </div>
    `;

    legend.innerHTML = [
      `<button class="legend-item ${state.umapFilter === "all" ? "is-active" : ""}" data-celltype="all">
        <span class="legend-left"><span class="swatch" style="background:linear-gradient(90deg,#3c7cff,#65c7f7)"></span><strong>全部</strong></span>
        <span class="muted">${fmt(umap.sampledCellCount)}</span>
      </button>`,
      ...counts.map(([cellType, count]) => {
        const color = points.find((point) => point.cellType === cellType)?.color || "#a9b0c3";
        return `<button class="legend-item ${state.umapFilter === cellType ? "is-active" : ""}" data-celltype="${cellType}">
          <span class="legend-left"><span class="swatch" style="background:${color}"></span><strong>${esc(zh(cellType))}</strong></span>
          <span class="muted">${fmt(count)}</span>
        </button>`;
      }),
    ].join("");

    legend.querySelectorAll(".legend-item").forEach((button) => {
      button.addEventListener("click", () => {
        state.umapFilter = button.dataset.celltype;
        renderUmap();
      });
    });
  }

  function renderGeneTable() {
    const tbody = $("#gene-table tbody");
    const rows = filteredGenes().slice(0, 60);
    if (!rows.some((row) => row.gene === state.selectedGene) && rows[0]) {
      state.selectedGene = rows[0].gene;
    }
    tbody.innerHTML = rows.map((row) => `
      <tr data-gene="${row.gene}" class="${row.gene === state.selectedGene ? "is-selected" : ""}">
        <td><strong>${esc(row.gene)}</strong><br><span class="muted">${esc(zh(row.cell_type_support || ""))}</span></td>
        <td>${fmt(row.best_total_priority_score)}</td>
        <td>${fmt(row.best_normal_celltype_score)}</td>
        <td>${fmt(row.best_disease_model_score)}</td>
        <td>${fmt(row.best_network_support_score)}</td>
      </tr>
    `).join("");
    tbody.querySelectorAll("tr").forEach((row) => {
      row.addEventListener("click", () => {
        state.selectedGene = row.dataset.gene;
        renderGeneTable();
        renderGeneDetail();
        renderTopGeneChart();
      });
    });
  }

  function renderGeneDetail() {
    const gene = filteredGenes().find((row) => row.gene === state.selectedGene) || filteredGenes()[0];
    if (!gene) return;
    const detail = $("#gene-detail");
    detail.innerHTML = `
      <div class="panel-head">
        <div>
          <p class="eyebrow">当前选中基因</p>
          <h4>${esc(gene.gene)}</h4>
        </div>
        <span class="pill">总分 ${fmt(gene.best_total_priority_score)}</span>
      </div>
      <p class="muted">${esc(geneSummaryZh(gene))}</p>
      <div class="detail-score-grid">
        <div class="score-box"><strong>${fmt(gene.best_normal_celltype_score)}</strong><span>正常评分</span></div>
        <div class="score-box"><strong>${fmt(gene.best_disease_model_score)}</strong><span>疾病评分</span></div>
        <div class="score-box"><strong>${fmt(gene.best_network_support_score)}</strong><span>网络评分</span></div>
        <div class="score-box"><strong>${fmt(gene.best_scrna_support_score)}</strong><span>单细胞总分</span></div>
      </div>
      <div class="detail-section">
        <h5>细胞类型支持</h5>
        <div class="chip-row">${chipList(gene.normal_celltype_expression_support)}</div>
      </div>
      <div class="detail-section">
        <h5>疾病模型证据</h5>
        <div class="chip-row">${chipList(gene.disease_model_support)}</div>
        <p class="muted">${esc(toList(gene.disease_model_detail).slice(0, 16).join(" · "))}</p>
      </div>
      <div class="detail-section">
        <h5>共表达模块</h5>
        <div class="chip-row">
          <span class="chip">${esc(gene.coexpression_module_support || "—")}</span>
          <span class="chip">${esc(zh(gene.coexpression_module_celltype_support || ""))}</span>
          <span class="chip">anchor: ${esc(toList(gene.coexpression_module_anchor_genes).slice(0, 5).join(", "))}</span>
        </div>
      </div>
      <div class="detail-section">
        <h5>模型覆盖</h5>
        <div class="chip-row">${chipList(gene.module_network_disease_models)}</div>
      </div>
    `;
    renderScoreHeatmap();
    renderModelHeatmap();
  }

  function renderVariants() {
    const tbody = $("#variant-table tbody");
    tbody.innerHTML = data.topVariants.map((row) => `
      <tr data-variant="${esc(row.variant)}" class="${row.variant === state.selectedVariant ? "is-selected" : ""}">
        <td><strong>${esc(row.gene)}</strong></td>
        <td>${esc(row.variant)}</td>
        <td>${esc(row.family_id)}</td>
        <td>${fmt(row.total_priority_score)}</td>
      </tr>
    `).join("");
    tbody.querySelectorAll("tr").forEach((row) => {
      row.addEventListener("click", () => {
        state.selectedVariant = row.dataset.variant;
        renderVariants();
        renderVariantDetail();
      });
    });
  }

  function renderVariantDetail() {
    const variant = data.topVariants.find((row) => row.variant === state.selectedVariant) || data.topVariants[0];
    if (!variant) return;
    $("#variant-detail").innerHTML = `
      <div class="variant-card">
        <h5>${esc(variant.gene)}</h5>
        <p><strong>${esc(variant.variant)}</strong></p>
        <p class="muted">${esc(variant.family_id)} · ${esc(variant.sample_id)}</p>
        <div class="detail-score-grid">
          <div class="score-box"><strong>${fmt(variant.normal_celltype_score)}</strong><span>正常</span></div>
          <div class="score-box"><strong>${fmt(variant.disease_model_score)}</strong><span>疾病</span></div>
          <div class="score-box"><strong>${fmt(variant.network_support_score)}</strong><span>网络</span></div>
          <div class="score-box"><strong>${fmt(variant.total_priority_score)}</strong><span>总分</span></div>
        </div>
        <div class="chip-row">${chipList(variant.disease_model_support)}</div>
        <p class="muted">${esc(variantSummaryZh(variant))}</p>
      </div>
    `;
  }

  function renderModules() {
    const selected = data.modules.find((item) => item.module_id === state.selectedModule) || data.modules[0];
    $("#module-cards").innerHTML = data.modules.map((module) => `
      <button class="module-card ${module.module_id === state.selectedModule ? "is-active" : ""}" data-module="${esc(module.module_id)}">
        <div class="panel-head">
          <h5>${esc(module.module_id)}</h5>
          <span class="pill">${esc(zh(module.dominant_celltype))}</span>
        </div>
        <div class="detail-meta">
          <span class="chip">${fmt(module.module_size)} 个基因</span>
          <span class="chip">${fmt(module.public_rp_gene_count)} 个 RP 基因</span>
          <span class="chip">${fmt(module.disease_gene_fraction, 4)} 扰动比例</span>
        </div>
        <p class="muted">anchor: ${esc(toList(module.anchor_genes).join(", "))}</p>
        <div class="chip-row">${chipList(module.disease_models, "tiny-chip")}</div>
      </button>
    `).join("") + (selected ? `
      <article class="module-card module-detail-card">
        <h5>${esc(selected.module_id)} 详情</h5>
        <p class="muted">${esc(zh(selected.dominant_celltype))} 主导；最大绝对扰动 ${fmt(selected.disease_max_abs_log2fc, 4)}</p>
        <div class="chip-row">
          <span class="chip">成员数 ${fmt(selected.module_size)}</span>
          <span class="chip">疾病命中 ${fmt(selected.disease_gene_count)}</span>
          <span class="chip">公共 RP 基因 ${fmt(selected.public_rp_gene_count)}</span>
        </div>
        <div class="detail-section">
          <h5>疾病上下文</h5>
          <p class="muted">${esc(toList(selected.disease_contexts).join(" · "))}</p>
        </div>
      </article>
    ` : "");

    $$("#module-cards .module-card[data-module]").forEach((button) => {
      button.addEventListener("click", () => {
        state.selectedModule = button.dataset.module;
        renderModules();
        renderModuleChart();
      });
    });
    renderModuleChart();
  }

  function renderWorkflow() {
    $("#workflow-steps").innerHTML = data.workflow.map((step, index) => {
      const [title, summary] = workflowCopy(step);
      return `
      <div class="workflow-step">
        <div class="step-number">${index + 1}</div>
        <div>
          <p class="eyebrow">${esc(title)}</p>
          <p class="muted">${esc(summary)}</p>
          <div class="chip-row">${step.outputs.map((output) => `<span class="chip">${esc(output)}</span>`).join("")}</div>
        </div>
      </div>
    `;
    }).join("");
    renderWorkflowMatrix();
  }

  function renderScoreHeatmap() {
    const svg = $("#score-heatmap");
    const genes = data.topGenes.slice(0, 20);
    const cols = [
      { key: "best_normal_celltype_score", label: "正常" },
      { key: "best_disease_model_score", label: "疾病" },
      { key: "best_network_support_score", label: "网络" },
      { key: "best_total_priority_score", label: "总分" },
    ];
    const left = 132;
    const top = 58;
    const cellW = 110;
    const cellH = 18;
    const maxRows = genes.length;
    const chartW = left + cols.length * cellW + 24;
    const chartH = top + maxRows * cellH + 34;
    const selected = state.selectedGene;
    const cells = [];
    genes.forEach((row, rIdx) => {
      cols.forEach((col, cIdx) => {
        const max = data.scoreRanges[col.key.includes("total") ? "total" : col.key.includes("normal") ? "normal" : col.key.includes("disease") ? "disease" : "network"] || 1;
        const value = row[col.key] || 0;
        const t = Math.max(0.08, value / max);
        const [start, end] = SCORE_COLORS[col.key];
        cells.push(`<rect x="${left + cIdx * cellW}" y="${top + rIdx * cellH}" width="${cellW - 6}" height="${cellH - 2}" rx="6" ry="6" fill="${scoreGradient(start, end, t)}" opacity="${selected && selected !== row.gene ? 0.45 : 1}"></rect>`);
        cells.push(`<text x="${left + cIdx * cellW + (cellW - 6) / 2}" y="${top + rIdx * cellH + 12}" text-anchor="middle" class="tooltip-note">${fmt(value)}</text>`);
      });
    });
    svg.setAttribute("viewBox", `0 0 ${chartW} ${chartH}`);
    svg.innerHTML = `
      <rect width="${chartW}" height="${chartH}" fill="rgba(255,255,255,0.86)"></rect>
      <text x="20" y="28" class="chart-title">前 20 基因三评分热图</text>
      ${cols.map((col, idx) => `<text x="${left + idx * cellW + 50}" y="${top - 14}" text-anchor="middle" class="axis-title">${col.label}</text>`).join("")}
      ${genes.map((row, idx) => `<text x="${left - 12}" y="${top + idx * cellH + 12}" text-anchor="end" class="axis-label" fill="${selected === row.gene ? "#111111" : "#5f6980"}">${esc(row.gene)}</text>`).join("")}
      ${cells.join("")}
    `;
  }

  function renderModelHeatmap() {
    const svg = $("#model-heatmap");
    const genes = data.topGenes.slice(0, 20);
    const left = 132;
    const top = 58;
    const cellW = 140;
    const cellH = 18;
    const selected = state.selectedGene;
    svg.setAttribute("viewBox", `0 0 ${left + MODEL_KEYS.length * cellW + 24} ${top + genes.length * cellH + 34}`);
    const cells = [];
    genes.forEach((row, rIdx) => {
      const models = String(row.module_network_disease_models || row.disease_dataset_hits || "");
      MODEL_KEYS.forEach((model, cIdx) => {
        const hit = models.toLowerCase().includes(model.key);
        cells.push(`<rect x="${left + cIdx * cellW}" y="${top + rIdx * cellH}" width="${cellW - 6}" height="${cellH - 2}" rx="6" ry="6" fill="${hit ? "#3c7cff" : "#edf1fb"}" opacity="${selected && selected !== row.gene ? 0.45 : 1}"></rect>`);
      });
    });
    svg.innerHTML = `
      <rect width="100%" height="100%" fill="rgba(255,255,255,0.86)"></rect>
      <text x="20" y="28" class="chart-title">前 20 基因疾病模型覆盖</text>
      ${MODEL_KEYS.map((model, idx) => `<text x="${left + idx * cellW + 58}" y="${top - 14}" text-anchor="middle" class="axis-title">${model.label}</text>`).join("")}
      ${genes.map((row, idx) => `<text x="${left - 12}" y="${top + idx * cellH + 12}" text-anchor="end" class="axis-label" fill="${selected === row.gene ? "#111111" : "#5f6980"}">${esc(row.gene)}</text>`).join("")}
      ${cells.join("")}
    `;
  }

  function renderModuleChart() {
    const svg = $("#module-chart");
    const modules = data.modules;
    const selected = state.selectedModule;
    const width = 920;
    const height = 520;
    const baseY = 420;
    const left = 90;
    const barW = 180;
    const gap = 110;
    const maxSize = Math.max(...modules.map((m) => m.module_size || 0), 1);
    svg.setAttribute("viewBox", `0 0 ${width} ${height}`);
    svg.innerHTML = `
      <rect width="${width}" height="${height}" fill="rgba(255,255,255,0.86)"></rect>
      <text x="32" y="36" class="chart-title">模块规模与疾病扰动比例</text>
      <line x1="${left}" y1="${baseY}" x2="${width - 40}" y2="${baseY}" stroke="rgba(17,17,17,0.12)"></line>
      ${modules.map((module, idx) => {
        const x = left + idx * (barW + gap);
        const barH = (module.module_size / maxSize) * 250;
        const color = selected === module.module_id ? "#3c7cff" : idx === 0 ? "#5a81ff" : "#8b5cf6";
        const lineY = 120 + (1 - (module.disease_gene_fraction || 0)) * 240;
        return `
          <g>
            <rect x="${x}" y="${baseY - barH}" width="${barW}" height="${barH}" rx="18" ry="18" fill="${color}" opacity="${selected === module.module_id ? 1 : 0.78}"></rect>
            <text x="${x + barW / 2}" y="${baseY + 26}" text-anchor="middle" class="axis-title">${esc(module.module_id)}</text>
            <text x="${x + barW / 2}" y="${baseY + 46}" text-anchor="middle" class="axis-label">${esc(zh(module.dominant_celltype))}</text>
            <text x="${x + barW / 2}" y="${baseY - barH - 10}" text-anchor="middle" class="tooltip-note">${fmt(module.module_size)} genes</text>
            <circle cx="${x + barW / 2}" cy="${lineY}" r="8" fill="#ff7c66"></circle>
            <text x="${x + barW / 2}" y="${lineY - 14}" text-anchor="middle" class="tooltip-note">${fmt(module.disease_gene_fraction, 4)}</text>
          </g>
        `;
      }).join("")}
      <text x="${width - 180}" y="92" class="axis-label">橙色圆点：疾病命中比例</text>
    `;
  }

  function renderWorkflowMatrix() {
    const svg = $("#workflow-matrix");
    const rows = [
      ["正常人视网膜", [1, 1, 1, 1]],
      ["RPGR 类器官", [0, 1, 1, 1]],
      ["rd1 小鼠", [0, 1, 1, 1]],
      ["rd10 小鼠", [0, 1, 1, 1]],
      ["WES 候选表", [0, 0, 0, 1]],
    ];
    const cols = ["下载读取", "正常/疾病评分", "网络支持", "最终排序"];
    const left = 150;
    const top = 80;
    const cellW = 150;
    const cellH = 54;
    svg.setAttribute("viewBox", `0 0 ${left + cols.length * cellW + 32} ${top + rows.length * cellH + 40}`);
    const cells = [];
    rows.forEach(([label, values], rIdx) => {
      values.forEach((value, cIdx) => {
        cells.push(`<rect x="${left + cIdx * cellW}" y="${top + rIdx * cellH}" width="${cellW - 8}" height="${cellH - 8}" rx="14" ry="14" fill="${value ? "#3c7cff" : "#eef2fb"}"></rect>`);
      });
    });
    svg.innerHTML = `
      <rect width="100%" height="100%" fill="rgba(255,255,255,0.86)"></rect>
      <text x="22" y="34" class="chart-title">数据源与评分链路矩阵</text>
      ${cols.map((col, idx) => `<text x="${left + idx * cellW + 58}" y="${top - 18}" text-anchor="middle" class="axis-title">${col}</text>`).join("")}
      ${rows.map(([label], idx) => `<text x="${left - 14}" y="${top + idx * cellH + 28}" text-anchor="end" class="axis-title">${label}</text>`).join("")}
      ${cells.join("")}
      <text x="${left}" y="${top + rows.length * cellH + 22}" class="axis-label">蓝色表示该数据源已经进入对应处理步骤</text>
    `;
  }

  function bindSearch() {
    $("#gene-search").addEventListener("input", (event) => {
      state.search = event.target.value;
      renderGeneTable();
      renderGeneDetail();
    });
  }

  function bindSortButtons() {
    $$(".seg-btn").forEach((button) => {
      button.addEventListener("click", () => {
        state.sortKey = button.dataset.sort;
        $$(".seg-btn").forEach((btn) => btn.classList.toggle("is-active", btn === button));
        renderGeneTable();
        renderGeneDetail();
      });
    });
  }

  function bindNav() {
    $$(".nav-link").forEach((button) => {
      button.addEventListener("click", () => {
        state.section = button.dataset.section;
        $$(".nav-link").forEach((btn) => btn.classList.toggle("is-active", btn === button));
        $$(".section").forEach((section) => section.classList.toggle("is-active", section.id === `section-${state.section}`));
      });
    });
  }

  function init() {
    renderMetrics();
    renderHeroNetwork();
    renderDatasets();
    renderKeyFindings();
    renderTopGeneChart();
    renderUmap();
    renderGeneTable();
    renderGeneDetail();
    renderVariants();
    renderVariantDetail();
    renderModules();
    renderWorkflow();
    bindSearch();
    bindSortButtons();
    bindNav();
  }

  init();
})();
