/* PAGINATION ENHANCER — Support 100+ companies */

const PaginationManager = {
  pageSize: 20,
  currentPage: 1,
  totalItems: 0,
  
  init(totalItems, pageSize = 20) {
    this.totalItems = totalItems;
    this.pageSize = pageSize;
    this.currentPage = 1;
  },
  
  paginate(items) {
    const start = (this.currentPage - 1) * this.pageSize;
    return items.slice(start, start + this.pageSize);
  },
  
  getTotalPages() {
    return Math.ceil(this.totalItems / this.pageSize);
  },
  
  canGoPrev() { return this.currentPage > 1; },
  canGoNext() { return this.currentPage < this.getTotalPages(); },
  
  goPage(n) {
    const max = this.getTotalPages();
    this.currentPage = Math.max(1, Math.min(n, max));
  },
  
  prev() { if(this.canGoPrev()) this.currentPage--; },
  next() { if(this.canGoNext()) this.currentPage++; },
  
  renderControls() {
    const total = this.getTotalPages();
    let html = '';
    
    // Previous button
    html += '<button class="btn btn-sm pagination-btn" ' + 
            (this.canGoPrev() ? 'onclick="PaginationManager.prev(); renderStatements()"' : 'disabled') +
            '>← Prev</button>';
    
    // Page numbers
    const maxShow = 7;
    const half = Math.floor(maxShow / 2);
    let start = Math.max(1, this.currentPage - half);
    let end = Math.min(total, start + maxShow - 1);
    if(end - start + 1 < maxShow) start = Math.max(1, end - maxShow + 1);
    
    if(start > 1) {
      html += '<button class="btn btn-sm pagination-btn" onclick="PaginationManager.goPage(1); renderStatements()">1</button>';
      if(start > 2) html += '<span class="pagination-ellipsis">…</span>';
    }
    
    for(let i = start; i <= end; i++) {
      html += '<button class="btn btn-sm pagination-btn ' + (i === this.currentPage ? 'active' : '') + '" ' +
              'onclick="PaginationManager.goPage(' + i + '); renderStatements()">' + i + '</button>';
    }
    
    if(end < total) {
      if(end < total - 1) html += '<span class="pagination-ellipsis">…</span>';
      html += '<button class="btn btn-sm pagination-btn" onclick="PaginationManager.goPage(' + total + '); renderStatements()">' + total + '</button>';
    }
    
    // Next button
    html += '<button class="btn btn-sm pagination-btn" ' + 
            (this.canGoNext() ? 'onclick="PaginationManager.next(); renderStatements()"' : 'disabled') +
            '>Next →</button>';
    
    // Info
    html += '<span class="pagination-info">Page ' + this.currentPage + ' of ' + total + 
            ' <span style="color:var(--text-faint);margin-left:8px;">(' + this.totalItems + ' total)</span></span>';
    
    return html;
  }
};

/* Query builder for 100 company — filter, search, sort */
const QueryBuilder = {
  filters: {
    terminal: null,
    company: null,
    dateFrom: null,
    dateTo: null,
    status: null
  },
  
  sortBy: 'date_desc',
  
  build() {
    let q = 'SELECT * FROM settlement_entries WHERE 1=1';
    const params = [];
    
    if(this.filters.terminal) {
      q += ' AND terminal_id = $' + (params.length + 1);
      params.push(this.filters.terminal);
    }
    if(this.filters.company) {
      q += ' AND operators.company ILIKE $' + (params.length + 1);
      params.push('%' + this.filters.company + '%');
    }
    if(this.filters.dateFrom) {
      q += ' AND entry_date >= $' + (params.length + 1);
      params.push(this.filters.dateFrom);
    }
    if(this.filters.dateTo) {
      q += ' AND entry_date <= $' + (params.length + 1);
      params.push(this.filters.dateTo);
    }
    if(this.filters.status) {
      q += ' AND status = $' + (params.length + 1);
      params.push(this.filters.status);
    }
    
    // Sort
    switch(this.sortBy) {
      case 'date_desc': q += ' ORDER BY entry_date DESC'; break;
      case 'date_asc': q += ' ORDER BY entry_date ASC'; break;
      case 'company_asc': q += ' ORDER BY operators.company ASC'; break;
      case 'amount_desc': q += ' ORDER BY final_amount DESC'; break;
    }
    
    return { sql: q, params };
  },
  
  reset() {
    this.filters = { terminal: null, company: null, dateFrom: null, dateTo: null, status: null };
    this.sortBy = 'date_desc';
  }
};

/* Index hint untuk Supabase — jalankan 1x saat setup */
const supabaseIndexes = [
  'CREATE INDEX IF NOT EXISTS idx_settlement_terminal_date ON settlement_entries(terminal_id, entry_date DESC);',
  'CREATE INDEX IF NOT EXISTS idx_settlement_operator_id ON settlement_entries(operator_id);',
  'CREATE INDEX IF NOT EXISTS idx_operator_company ON operators(company);',
  'CREATE INDEX IF NOT EXISTS idx_operator_terminal ON operators(terminal_id);',
];

console.log('Pagination Manager loaded — supports 100+ companies with smart filtering');
