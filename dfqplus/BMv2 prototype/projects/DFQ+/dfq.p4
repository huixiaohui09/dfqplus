/* -*- P4_16 -*- */
#include <core.p4>
#include <v1model.p4>

const bit<16> TYPE_IPV4 = 0x800;
const bit<8>  PROTOCOL_ICMP = 1;

/************** Queue / Window Parameters **************/
const int     NUM_QUEUES = 5;                 // Number of logical (virtual) queues
const bit<32> QUEUE_CAPACITY = 256;           // Capacity per queue (packets/slots)
const bit<32> SLOT_BYTES = 1500;              // Bytes per slot (for byte-level prefix comparison)
const int     WINDOW_W = 32;                  // Ring buffer size (maintain W8/W16/W32 in parallel)
const bit<32> AUX_QID = 4;                    // Reserved auxiliary queue qid
const bit<32> SPLIT_MIN_CHUNK = 1;            // Minimum transferable capacity (packets)

/************** Rate buckets (1ms time-based) **************/
const int     NB = 8;                         // Number of buckets (most recent NB * 1ms)

typedef bit<9>  egressSpec_t;
typedef bit<48> macAddr_t;
typedef bit<32> ip4Addr_t;

header ethernet_t {
    macAddr_t dstAddr;
    macAddr_t srcAddr;
    bit<16>   etherType;
}

header ipv4_t {
    bit<4>    version;
    bit<4>    ihl;
    bit<8>    diffserv;
    bit<16>   totalLen;
    bit<16>   identification;
    bit<3>    flags;
    bit<13>   fragOffset;
    bit<8>    ttl;
    bit<8>    protocol;
    bit<16>   hdrChecksum;
    ip4Addr_t srcAddr;
    ip4Addr_t dstAddr;
}

header icmp_t {
    bit<8> type;
    bit<8> code;
    bit<16> checksum;
}

struct metadata {
    bit<8>  flow_id;
    bit<8>  queue_id;        
    bit<1>  can_enqueue;
    bit<32> packet_size;    
    bit<1>  should_drop;
    bit<1>  queue_empty;

    bit<32> size0;
    bit<32> size1;
    bit<32> size2;
    bit<32> size3;
    bit<32> size4;

    bit<32> round_r;
    bit<32> omega_r;

    bit<5>  cur_qid;       
    bit<19> left19;         
}

struct headers {
    ethernet_t ethernet;
    ipv4_t     ipv4;
    icmp_t     icmp;
}

/************** Registers **************/
register<bit<32>>(NUM_QUEUES) queue_tail;
register<bit<32>>(NUM_QUEUES) queue_size;

/* Mapping and capacity */
register<bit<32>>(NUM_QUEUES) pri2qid;             // Priority -> qid mapping
register<bit<32>>(NUM_QUEUES) queue_cap_reg;       // Effective capacity (packets) per qid; 0 means "default"
register<bit<1>>(1)           init_done;           // Initialization flag

/* Split/merge state machine */
register<bit<1>>(1)           split_active;        // Whether currently in "split" state
register<bit<32>>(1)          split_head_qid;      // qid of the split head queue
register<bit<32>>(1)          split_aux_qid;       // qid of the auxiliary queue
register<bit<1>>(1)           rotation_done;       // Whether left-shift of priorities for this split round is done

/* Statistics / sample window */
register<bit<32>>(256)        flow_arrival_end_bits; // per-flow round (bytes)
register<bit<32>>(WINDOW_W)   win_rank;            // Round (bytes) for the last W samples
register<bit<32>>(WINDOW_W)   win_size;            // Size (bytes) for the last W samples
register<bit<32>>(1)          win_ptr;             // Ring pointer [0..W-1]

/* —— Multiple windows in parallel (discrete selection 8/16/32) —— */
register<bit<32>>(1)          sum_w8;
register<bit<32>>(1)          sum_w16;
register<bit<32>>(1)          sum_w32;
register<bit<2>>(1)           window_sel;          // 0→W8, 1→W16, 2→W32
const bit<32> ONE_THIRD_K = 21845; // ≈ 1/3 * 2^16
const bit<32> TWO_THIRD_K = 43691; // ≈ 2/3 * 2^16
register<bit<32>>(1)          pkt_in_count;        // Packet arrival counter (optional)

/*Global 1ms rate measurement (time-driven)*/
register<bit<32>>(NB)         rate_bins;           // Arrivals per "1ms bucket"
register<bit<32>>(1)          rate_ptr;            // Current bucket index [0..NB-1]
register<bit<64>>(1)          ms_anchor_us;        // Millisecond time anchor (us)

/* EWMA (packets/1ms) for relative thresholds*/
register<bit<32>>(1)          ewma_pkts;

/************** Parser **************/
parser MyParser(packet_in packet,
                out headers hdr,
                inout metadata meta,
                inout standard_metadata_t standard_metadata) {
    state start { transition parse_ethernet; }

    state parse_ethernet {
        packet.extract(hdr.ethernet);
        transition select(hdr.ethernet.etherType) {
            TYPE_IPV4: parse_ipv4;
            default: accept;
        }
    }

    state parse_ipv4 {
        packet.extract(hdr.ipv4);
        meta.packet_size = (bit<32>)hdr.ipv4.totalLen - ((bit<32>)hdr.ipv4.ihl << 2);
        meta.should_drop = 0;
        meta.queue_empty = 0;
        transition select(hdr.ipv4.protocol) {
            PROTOCOL_ICMP: parse_icmp;
            default: accept;
        }
    }

    state parse_icmp { packet.extract(hdr.icmp); transition accept; }
}

/************** Ingress **************/
control MyIngress(inout headers hdr,
                  inout metadata meta,
                  inout standard_metadata_t standard_metadata) {

    action drop_action() { mark_to_drop(standard_metadata); }

    action set_flow_id() {
        bit<6> dscp = (bit<6>)(hdr.ipv4.diffserv >> 2);
        meta.flow_id = (bit<8>)(dscp & 0x1F);
    }

    /* Initialization: if not initialized, write defaults; otherwise keep current values */
    action maybe_init_defaults() {
        bit<1> inited; init_done.read(inited, 0);

        // Read current mapping and capacity
        bit<32> p0; pri2qid.read(p0, 0);
        bit<32> p1; pri2qid.read(p1, 1);
        bit<32> p2; pri2qid.read(p2, 2);
        bit<32> p3; pri2qid.read(p3, 3);
        bit<32> p4; pri2qid.read(p4, 4);

        bit<32> cap0; queue_cap_reg.read(cap0, 0);
        bit<32> cap1; queue_cap_reg.read(cap1, 1);
        bit<32> cap2; queue_cap_reg.read(cap2, 2);
        bit<32> cap3; queue_cap_reg.read(cap3, 3);
        bit<32> cap4; queue_cap_reg.read(cap4, 4);

        bit<1> sa_prev;   split_active.read(sa_prev, 0);
        bit<32> sh_prev;  split_head_qid.read(sh_prev, 0);
        bit<32> saq_prev; split_aux_qid.read(saq_prev, 0);

        bit<32> rp_prev;   rate_ptr.read(rp_prev, 0);
        bit<64> anch_prev; ms_anchor_us.read(anch_prev, 0);

        bit<32> s8_prev;  sum_w8.read(s8_prev, 0);
        bit<32> s16_prev; sum_w16.read(s16_prev, 0);
        bit<32> s32_prev; sum_w32.read(s32_prev, 0);
        bit<2>  ws_prev;  window_sel.read(ws_prev, 0);

        bit<1> rot_prev;  rotation_done.read(rot_prev, 0);

        bit<32> ew_prev;  ewma_pkts.read(ew_prev, 0);

        // Write defaults or keep current
        pri2qid.write(0, (inited==1w1) ? p0 : 0);
        pri2qid.write(1, (inited==1w1) ? p1 : 1);
        pri2qid.write(2, (inited==1w1) ? p2 : 2);
        pri2qid.write(3, (inited==1w1) ? p3 : 3);
        pri2qid.write(4, (inited==1w1) ? p4 : 4);

        queue_cap_reg.write(0, (inited==1w1) ? cap0 : 0);
        queue_cap_reg.write(1, (inited==1w1) ? cap1 : 0);
        queue_cap_reg.write(2, (inited==1w1) ? cap2 : 0);
        queue_cap_reg.write(3, (inited==1w1) ? cap3 : 0);
        queue_cap_reg.write(4, (inited==1w1) ? cap4 : 0);

        split_active.write(0,   (inited==1w1) ? sa_prev  : 1w0);
        split_head_qid.write(0, (inited==1w1) ? sh_prev  : 0);
        split_aux_qid.write(0,  (inited==1w1) ? saq_prev : AUX_QID);

        rate_ptr.write(0,       (inited==1w1) ? rp_prev  : 0);
        ms_anchor_us.write(0,   (inited==1w1) ? anch_prev: 0);

        sum_w8.write(0,         (inited==1w1) ? s8_prev  : 0);
        sum_w16.write(0,        (inited==1w1) ? s16_prev : 0);
        sum_w32.write(0,        (inited==1w1) ? s32_prev : 0);
        window_sel.write(0,     (inited==1w1) ? ws_prev  : (bit<2>)2); // Default W32

        rotation_done.write(0,  (inited==1w1) ? rot_prev : 1w0);

        ewma_pkts.write(0,      (inited==1w1) ? ew_prev  : 0);

        init_done.write(0, 1w1);
    }

    // On arrival: update per-flow round & three window sums (O(1)) //
    action update_multi_windows() {
        bit<32> fid = (bit<32>) meta.flow_id;
        bit<32> end_prev; flow_arrival_end_bits.read(end_prev, fid);
        bit<32> r = end_prev + meta.packet_size;
        meta.round_r = r;
        flow_arrival_end_bits.write(fid, r);
        bit<32> ptr; win_ptr.read(ptr, 0);
        bit<32> old32; win_size.read(old32, ptr);

        // Index sliding out of W16
        bit<32> idx16 = ptr + 16;
        if (idx16 >= (bit<32>)WINDOW_W) { idx16 = idx16 - (bit<32>)WINDOW_W; }
        bit<32> old16; win_size.read(old16, idx16);

        // Index sliding out of W8
        bit<32> idx8 = ptr + 24;
        if (idx8 >= (bit<32>)WINDOW_W) { idx8 = idx8 - (bit<32>)WINDOW_W; }
        bit<32> old8; win_size.read(old8, idx8);

        bit<32> s8;  sum_w8.read(s8, 0);
        bit<32> s16; sum_w16.read(s16, 0);
        bit<32> s32; sum_w32.read(s32, 0);

        bit<32> new_sz = meta.packet_size;

        bit<32> s8_w  = s8  - old8  + new_sz;
        bit<32> s16_w = s16 - old16 + new_sz;
        bit<32> s32_w = s32 - old32 + new_sz;

        sum_w8.write(0,  s8_w);
        sum_w16.write(0, s16_w);
        sum_w32.write(0, s32_w);

        win_rank.write(ptr, r);
        win_size.write(ptr, new_sz);

        bit<32> ptr_inc = ptr + 1;
        bit<32> ptr_next = (ptr_inc >= (bit<32>)WINDOW_W) ? 0 : ptr_inc;
        win_ptr.write(0, ptr_next);

        // Packet arrival counter (for stats)
        bit<32> pc;  pkt_in_count.read(pc, 0);
        pkt_in_count.write(0, pc + 1);
    }

    /* 1ms rate measurement */
    action update_rate_1ms() {
        bit<64> now_us = (bit<64>) standard_metadata.ingress_global_timestamp;

        // Read anchor and ptr
        bit<64> anchor;  ms_anchor_us.read(anchor, 0);
        bit<32> ptr;     rate_ptr.read(ptr, 0);

        // Initialize anchor to current time if needed
        bit<1>  need_init = (anchor == 0) ? 1w1 : 1w0;
        bit<64> anchor_w = (need_init == 1w1) ? now_us : anchor;
        ms_anchor_us.write(0, anchor_w);

        // Read back
        ms_anchor_us.read(anchor, 0);
        rate_ptr.read(ptr, 0);

        // Compute diff and steps (comparison chain)
        bit<64> diff_us = (now_us > anchor) ? (now_us - anchor) : 0;

        bit<32> steps = 0;
        if (diff_us >= (bit<64>)8000)      { steps = (bit<32>)8; }
        else if (diff_us >= (bit<64>)7000) { steps = (bit<32>)7; }
        else if (diff_us >= (bit<64>)6000) { steps = (bit<32>)6; }
        else if (diff_us >= (bit<64>)5000) { steps = (bit<32>)5; }
        else if (diff_us >= (bit<64>)4000) { steps = (bit<32>)4; }
        else if (diff_us >= (bit<64>)3000) { steps = (bit<32>)3; }
        else if (diff_us >= (bit<64>)2000) { steps = (bit<32>)2; }
        else if (diff_us >= (bit<64>)1000) { steps = (bit<32>)1; }
        else                               { steps = (bit<32>)0; }

        // Zero out buckets we will pass
        bit<32> idx1 = ptr + 1;  if (idx1 >= (bit<32>)NB) { idx1 = idx1 - (bit<32>)NB; }
        bit<32> old1; rate_bins.read(old1, idx1);
        bit<32> val1 = ((steps > (bit<32>)1) ? (bit<32>)0 : old1);
        rate_bins.write(idx1, val1);

        bit<32> idx2 = ptr + 2;  if (idx2 >= (bit<32>)NB) { idx2 = idx2 - (bit<32>)NB; }
        bit<32> old2; rate_bins.read(old2, idx2);
        bit<32> val2 = ((steps > (bit<32>)2) ? (bit<32>)0 : old2);
        rate_bins.write(idx2, val2);

        bit<32> idx3 = ptr + 3;  if (idx3 >= (bit<32>)NB) { idx3 = idx3 - (bit<32>)NB; }
        bit<32> old3; rate_bins.read(old3, idx3);
        bit<32> val3 = ((steps > (bit<32>)3) ? (bit<32>)0 : old3);
        rate_bins.write(idx3, val3);

        bit<32> idx4 = ptr + 4;  if (idx4 >= (bit<32>)NB) { idx4 = idx4 - (bit<32>)NB; }
        bit<32> old4; rate_bins.read(old4, idx4);
        bit<32> val4 = ((steps > (bit<32>)4) ? (bit<32>)0 : old4);
        rate_bins.write(idx4, val4);

        bit<32> idx5 = ptr + 5;  if (idx5 >= (bit<32>)NB) { idx5 = idx5 - (bit<32>)NB; }
        bit<32> old5; rate_bins.read(old5, idx5);
        bit<32> val5 = ((steps > (bit<32>)5) ? (bit<32>)0 : old5);
        rate_bins.write(idx5, val5);

        bit<32> idx6 = ptr + 6;  if (idx6 >= (bit<32>)NB) { idx6 = idx6 - (bit<32>)NB; }
        bit<32> old6; rate_bins.read(old6, idx6);
        bit<32> val6 = ((steps > (bit<32>)6) ? (bit<32>)0 : old6);
        rate_bins.write(idx6, val6);

        bit<32> idx7 = ptr + 7;  if (idx7 >= (bit<32>)NB) { idx7 = idx7 - (bit<32>)NB; }
        bit<32> old7; rate_bins.read(old7, idx7);
        bit<32> val7 = ((steps > (bit<32>)7) ? (bit<32>)0 : old7);
        rate_bins.write(idx7, val7);

        bit<32> idx8 = ptr + 8;  if (idx8 >= (bit<32>)NB) { idx8 = idx8 - (bit<32>)NB; }
        bit<32> old8; rate_bins.read(old8, idx8);
        bit<32> val8 = ((steps > (bit<32>)8) ? (bit<32>)0 : old8);
        rate_bins.write(idx8, val8);

        // Update ptr and anchor
        bit<32> ptr_steps = ptr + steps;
        bit<32> new_ptr = (ptr_steps >= (bit<32>)NB) ? (ptr_steps - (bit<32>)NB) : ptr_steps;
        rate_ptr.write(0, new_ptr);

        bit<64> new_anchor = anchor + (bit<64>)steps * (bit<64>)1000;
        ms_anchor_us.write(0, new_anchor);

        // Count this packet in the current bucket
        bit<32> cur; rate_bins.read(cur, new_ptr);
        rate_bins.write(new_ptr, cur + 1);
    }

    /* Compute Omega_r by window scan */
    action compute_omega_by_window_scan() {
        bit<32> r = meta.round_r;
        bit<32> sum = 0;

        bit<32> rk; bit<32> sz;

        win_rank.read(rk, 0);  win_size.read(sz, 0);  if (rk <= r) { sum = sum + sz; }
        win_rank.read(rk, 1);  win_size.read(sz, 1);  if (rk <= r) { sum = sum + sz; }
        win_rank.read(rk, 2);  win_size.read(sz, 2);  if (rk <= r) { sum = sum + sz; }
        win_rank.read(rk, 3);  win_size.read(sz, 3);  if (rk <= r) { sum = sum + sz; }
        win_rank.read(rk, 4);  win_size.read(sz, 4);  if (rk <= r) { sum = sum + sz; }
        win_rank.read(rk, 5);  win_size.read(sz, 5);  if (rk <= r) { sum = sum + sz; }
        win_rank.read(rk, 6);  win_size.read(sz, 6);  if (rk <= r) { sum = sum + sz; }
        win_rank.read(rk, 7);  win_size.read(sz, 7);  if (rk <= r) { sum = sum + sz; }

        win_rank.read(rk, 8);  win_size.read(sz, 8);  if (rk <= r) { sum = sum + sz; }
        win_rank.read(rk, 9);  win_size.read(sz, 9);  if (rk <= r) { sum = sum + sz; }
        win_rank.read(rk,10);  win_size.read(sz,10);  if (rk <= r) { sum = sum + sz; }
        win_rank.read(rk,11);  win_size.read(sz,11);  if (rk <= r) { sum = sum + sz; }
        win_rank.read(rk,12);  win_size.read(sz,12);  if (rk <= r) { sum = sum + sz; }
        win_rank.read(rk,13);  win_size.read(sz,13);  if (rk <= r) { sum = sum + sz; }
        win_rank.read(rk,14);  win_size.read(sz,14);  if (rk <= r) { sum = sum + sz; }
        win_rank.read(rk,15);  win_size.read(sz,15);  if (rk <= r) { sum = sum + sz; }

        win_rank.read(rk,16);  win_size.read(sz,16);  if (rk <= r) { sum = sum + sz; }
        win_rank.read(rk,17);  win_size.read(sz,17);  if (rk <= r) { sum = sum + sz; }
        win_rank.read(rk,18);  win_size.read(sz,18);  if (rk <= r) { sum = sum + sz; }
        win_rank.read(rk,19);  win_size.read(sz,19);  if (rk <= r) { sum = sum + sz; }
        win_rank.read(rk,20);  win_size.read(sz,20);  if (rk <= r) { sum = sum + sz; }
        win_rank.read(rk,21);  win_size.read(sz,21);  if (rk <= r) { sum = sum + sz; }
        win_rank.read(rk,22);  win_size.read(sz,22);  if (rk <= r) { sum = sum + sz; }
        win_rank.read(rk,23);  win_size.read(sz,23);  if (rk <= r) { sum = sum + sz; }

        win_rank.read(rk,24);  win_size.read(sz,24);  if (rk <= r) { sum = sum + sz; }
        win_rank.read(rk,25);  win_size.read(sz,25);  if (rk <= r) { sum = sum + sz; }
        win_rank.read(rk,26);  win_size.read(sz,26);  if (rk <= r) { sum = sum + sz; }
        win_rank.read(rk,27);  win_size.read(sz,27);  if (rk <= r) { sum = sum + sz; }
        win_rank.read(rk,28);  win_size.read(sz,28);  if (rk <= r) { sum = sum + sz; }
        win_rank.read(rk,29);  win_size.read(sz,29);  if (rk <= r) { sum = sum + sz; }
        win_rank.read(rk,30);  win_size.read(sz,30);  if (rk <= r) { sum = sum + sz; }
        win_rank.read(rk,31);  win_size.read(sz,31);  if (rk <= r) { sum = sum + sz; }

        meta.omega_r = sum;
    }

    /* Window-boundary capacity split trigger */
    action maybe_trigger_split_window() {
        bit<32> ptr; win_ptr.read(ptr, 0);
        bit<1>  split; split_active.read(split, 0);

        bit<32> q0; pri2qid.read(q0, 0);

        bit<32> cap_head; queue_cap_reg.read(cap_head, q0);
        bit<32> cap_aux;  queue_cap_reg.read(cap_aux,  AUX_QID);
        bit<32> size_head; queue_size.read(size_head, q0);

        bit<32> cap_head_eff = (cap_head == 0) ? QUEUE_CAPACITY : cap_head;
        bit<32> free_head = (size_head < cap_head_eff) ? (cap_head_eff - size_head) : 0;

        bit<32> give_base = free_head;
        bit<32> give_sel1 = (give_base < SPLIT_MIN_CHUNK) ? SPLIT_MIN_CHUNK : give_base;

        bit<1> at_boundary = (ptr == 0) ? 1w1 : 1w0;
        bit<1> can_split   = (at_boundary == 1w1 && split == 1w0 && free_head >= SPLIT_MIN_CHUNK) ? 1w1 : 1w0;

        bit<32> give = (can_split == 1w1) ? give_sel1 : 0;

        bit<32> cap_head_new = (cap_head == 0) ? (QUEUE_CAPACITY - give) : (cap_head - give);
        bit<32> cap_aux_new  = cap_aux + give;

        queue_cap_reg.write(q0,      cap_head_new);
        queue_cap_reg.write(AUX_QID, cap_aux_new);

        // Record split info; reset rotation_done at the start of a new split round
        bit<32> sh_prev; split_head_qid.read(sh_prev, 0);
        bit<32> sh_w = (can_split==1w1) ? q0 : sh_prev;
        split_head_qid.write(0, sh_w);

        bit<32> sa_prev; split_aux_qid.read(sa_prev, 0);
        bit<32> sa_w = (can_split==1w1) ? AUX_QID : sa_prev;
        split_aux_qid.write(0, sa_w);

        bit<1> split_new = (can_split==1w1) ? 1w1 : split;
        split_active.write(0, split_new);

        bit<1> rot_prev; rotation_done.read(rot_prev, 0);
        bit<1> rot_w = (can_split==1w1) ? 1w0 : rot_prev;
        rotation_done.write(0, rot_w);
    }

    // Boundary: EWMA-based relative threshold + c/C binning, select window size (LUT) //
    action select_window_at_boundary() {
        bit<32> ptr_now; win_ptr.read(ptr_now, 0);
        bit<1>  at_boundary = (ptr_now == 0) ? 1w1 : 1w0;
        bit<32> b;
        bit<32> s = 0;
        rate_bins.read(b, 0); s = s + b;
        rate_bins.read(b, 1); s = s + b;
        rate_bins.read(b, 2); s = s + b;
        rate_bins.read(b, 3); s = s + b;
        rate_bins.read(b, 4); s = s + b;
        rate_bins.read(b, 5); s = s + b;
        rate_bins.read(b, 6); s = s + b;
        rate_bins.read(b, 7); s = s + b;

        // Update EWMA (α=1/8)
        bit<32> m_prev; ewma_pkts.read(m_prev, 0);
        bit<32> m_dec = m_prev - (m_prev >> 3);   // m_prev * (1 - 1/8)
        bit<32> s_inc = (s >> 3);                 // s * (1/8)
        bit<32> m_raw = m_dec + s_inc;            // Regular EWMA
        bit<1>  m_boot = (m_prev == (bit<32>)0) ? 1w1 : 1w0;
        bit<32> m = (m_boot == 1w1) ? s : m_raw;  // Bootstrap: m = s
        ewma_pkts.write(0, m);

        // λ binning (LOW/MID/HIGH -> 0/1/2) based on relative thresholds
        // Low threshold: 0.75*m  =>  s*4 < m*3
        bit<64> s_x4 = (bit<64>)((bit<64>)s << 2);      // s*4
        bit<64> m_x3 = (bit<64>)m * (bit<64>)3;         // m*3
        bit<1> is_low = (s_x4 < m_x3) ? 1w1 : 1w0;

        // High threshold: 1.5*m  =>  s*2 > m*3
        bit<64> s_x2 = (bit<64>)((bit<64>)s << 1);      // s*2
        bit<1> is_high = (s_x2 > m_x3) ? 1w1 : 1w0;
        
        bit<2> lam_class = 
        (is_low == 1w1) ? (bit<2>)0 : ((is_high == 1w1) ? (bit<2>)2 : (bit<2>)1);

        // Read the head-queue occupancy and bin c/C (LIGHT/MID/HEAVY -> 0/1/2)
        bit<32> q0; pri2qid.read(q0, 0);
        bit<32> size0; queue_size.read(size0, q0);
        bit<32> cap0r; queue_cap_reg.read(cap0r, q0);
        bit<32> cap0 = (cap0r == 0) ? QUEUE_CAPACITY : cap0r;

        bit<32> th1 = (cap0 * ONE_THIRD_K) >> 16;
        bit<32> th2 = (cap0 * TWO_THIRD_K) >> 16;

        bit<2> load_class = (size0 < th1) ? (bit<2>)0
                              : ((size0 < th2) ? (bit<2>)1 : (bit<2>)2);

        // LUT: choose window_sel according to the table mapping
        bit<2> ws_prev; window_sel.read(ws_prev, 0);
        bit<2> ws_new = ws_prev;

        if (lam_class == (bit<2>)0) {
            // λ = Low (0) -> W32 for all loads
            ws_new = (bit<2>)2; // W32
        } else if (lam_class == (bit<2>)1) {
            // λ = Medium (1) -> Light: W16; Medium/Heavy: W32
            if (load_class == (bit<2>)0) { ws_new = (bit<2>)1; } // W16
            else                         { ws_new = (bit<2>)2; } // W32
        } else {
            // λ = High (2) -> Light: W8; Medium/Heavy: W32
            if (load_class == (bit<2>)0) { ws_new = (bit<2>)0; } // W8
            else                         { ws_new = (bit<2>)2; } // W32
        }

        window_sel.write(0, ws_new);
    }

    // Admission
    action dfq_admission() {
        /* Read priority mapping */
        bit<32> q0; pri2qid.read(q0, 0);
        bit<32> q1; pri2qid.read(q1, 1);
        bit<32> q2; pri2qid.read(q2, 2);
        bit<32> q3; pri2qid.read(q3, 3);
        bit<32> q4; pri2qid.read(q4, 4);

        /* Read size and cap_reg per queue, compute cap_eff and remaining S_i*/
        bit<32> s0; queue_size.read(s0, q0);
        bit<32> s1; queue_size.read(s1, q1);
        bit<32> s2; queue_size.read(s2, q2);
        bit<32> s3; queue_size.read(s3, q3);
        bit<32> s4; queue_size.read(s4, q4);

        bit<32> cr0; queue_cap_reg.read(cr0, q0);
        bit<32> cr1; queue_cap_reg.read(cr1, q1);
        bit<32> cr2; queue_cap_reg.read(cr2, q2);
        bit<32> cr3; queue_cap_reg.read(cr3, q3);
        bit<32> cr4; queue_cap_reg.read(cr4, q4);

        bit<32> cap0 = (cr0 == 0) ? QUEUE_CAPACITY : cr0;
        bit<32> cap1 = (cr1 == 0) ? QUEUE_CAPACITY : cr1;
        bit<32> cap2 = (cr2 == 0) ? QUEUE_CAPACITY : cr2;
        bit<32> cap3 = (cr3 == 0) ? QUEUE_CAPACITY : cr3;
        bit<32> cap4 = (cr4 == 0) ? ((q4 == AUX_QID) ? 0 : QUEUE_CAPACITY) : cr4; 

        bit<32> S0 = (s0 < cap0) ? (cap0 - s0) : 0;
        bit<32> S1 = (s1 < cap1) ? (cap1 - s1) : 0;
        bit<32> S2 = (s2 < cap2) ? (cap2 - s2) : 0;
        bit<32> S3 = (s3 < cap3) ? (cap3 - s3) : 0;
        bit<32> S4 = (s4 < cap4) ? (cap4 - s4) : 0;

        bit<32> SB0 = S0 * SLOT_BYTES;
        bit<32> SB1 = S1 * SLOT_BYTES;
        bit<32> SB2 = S2 * SLOT_BYTES;
        bit<32> SB3 = S3 * SLOT_BYTES;
        bit<32> SB4 = S4 * SLOT_BYTES;

        bit<32> P1 = SB0;
        bit<32> P2 = P1 + SB1;
        bit<32> P3 = P2 + SB2;
        bit<32> P4 = P3 + SB3;
        bit<32> P5 = P4 + SB4;

        /* Decide target qid */
        meta.can_enqueue = 0;
        if (meta.omega_r <= P1)       { meta.queue_id = (bit<8>)q0; meta.can_enqueue = 1; }
        else if (meta.omega_r <= P2)  { meta.queue_id = (bit<8>)q1; meta.can_enqueue = 1; }
        else if (meta.omega_r <= P3)  { meta.queue_id = (bit<8>)q2; meta.can_enqueue = 1; }
        else if (meta.omega_r <= P4)  { meta.queue_id = (bit<8>)q3; meta.can_enqueue = 1; }
        else if (meta.omega_r <= P5)  { meta.queue_id = (bit<8>)q4; meta.can_enqueue = 1; }
        else                          { meta.should_drop = 1w1; }

        bit<32> qid_32 = (bit<32>)meta.queue_id;

        bit<32> cap_sel;
        if (qid_32 == q0)      { cap_sel = cap0; }
        else if (qid_32 == q1) { cap_sel = cap1; }
        else if (qid_32 == q2) { cap_sel = cap2; }
        else if (qid_32 == q3) { cap_sel = cap3; }
        else                   { cap_sel = cap4; }

        bit<32> tail_idx;  queue_tail.read(tail_idx, qid_32);
        bit<32> cur_sz;    queue_size.read(cur_sz, qid_32);

        bit<1> fit_cap = (cur_sz < cap_sel) ? 1w1 : 1w0;
        bit<1> do_enq  = (meta.can_enqueue == 1w1 && fit_cap == 1w1) ? 1w1 : 1w0;

        bit<32> tail_next = (tail_idx + 1 >= cap_sel) ? 0 : (tail_idx + 1);
        bit<32> tail_w    = (do_enq == 1w1) ? tail_next : tail_idx;
        bit<32> size_w    = (do_enq == 1w1) ? (cur_sz + 1) : cur_sz;

        queue_tail.write(qid_32, tail_w);
        queue_size .write(qid_32, size_w);

        if (meta.can_enqueue == 1w1 && fit_cap == 1w0) { meta.should_drop = 1w1; }
        if (do_enq == 1w1) { meta.can_enqueue = 1w1; }
        else if (meta.should_drop != 1w1) { meta.can_enqueue = 1w0; }

        if (meta.can_enqueue == 1w1) {
            standard_metadata.priority = (bit<5>) meta.queue_id;
        }
    }

    action ipv4_forward(macAddr_t dstAddr, egressSpec_t port) {
        standard_metadata.egress_spec = port;
        hdr.ethernet.srcAddr = hdr.ethernet.dstAddr;
        hdr.ethernet.dstAddr = dstAddr;
        hdr.ipv4.ttl = hdr.ipv4.ttl - 1;
        hdr.ipv4.identification = (bit<16>)port;
    }

    table ipv4_lpm {
        key = { hdr.ipv4.dstAddr: lpm; }
        actions = { ipv4_forward; drop_action; }
        size = 1024;
        default_action = drop_action();
    }

    apply {
        if (hdr.ipv4.isValid() && hdr.icmp.isValid() && hdr.icmp.type == 8) {
            maybe_init_defaults();
            set_flow_id();

            if (ipv4_lpm.apply().hit) {
                update_multi_windows();        // O(1) update for W8/W16/W32 window sums
                update_rate_1ms();             // 1ms rate accounting
                select_window_at_boundary();   // At window boundary: select W via EWMA and c/C binning
                maybe_trigger_split_window();  // At boundary: try split (capacity transfer) and reset rotation_done
                compute_omega_by_window_scan();// Ω_r by prefix over rounds
                dfq_admission();

                if (meta.should_drop == 1w1) { drop_action(); return; }
            } else {
                drop_action(); return;
            }
        }
    }
}

/************** Egress **************/
control MyEgress(inout headers hdr,
                 inout metadata meta,
                 inout standard_metadata_t standard_metadata) {

    /* When "split head queue capacity == 0" and not rotated yet, perform one left-shift of priorities */
    action maybe_rotate_on_cap0() {
        bit<1>  split;     split_active.read(split, 0);
        bit<32> head_qid;  split_head_qid.read(head_qid, 0);
        bit<1>  rot_done;  rotation_done.read(rot_done, 0);

        // Current effective capacity of head queue
        bit<32> cap_head;  queue_cap_reg.read(cap_head, head_qid);

        // Current priority mapping
        bit<32> p0; pri2qid.read(p0, 0);
        bit<32> p1; pri2qid.read(p1, 1);
        bit<32> p2; pri2qid.read(p2, 2);
        bit<32> p3; pri2qid.read(p3, 3);
        bit<32> p4; pri2qid.read(p4, 4);

        // Trigger condition
        bit<1> do_rot = (split == 1w1 && cap_head == 0 && rot_done == 1w0) ? 1w1 : 1w0;

        // Left-shifted priority mapping
        bit<32> np0 = (do_rot==1w1) ? p1 : p0;
        bit<32> np1 = (do_rot==1w1) ? p2 : p1;
        bit<32> np2 = (do_rot==1w1) ? p3 : p2;
        bit<32> np3 = (do_rot==1w1) ? p4 : p3;
        bit<32> np4 = (do_rot==1w1) ? p0 : p4; 

        pri2qid.write(0, np0);
        pri2qid.write(1, np1);
        pri2qid.write(2, np2);
        pri2qid.write(3, np3);
        pri2qid.write(4, np4);

        // Sync the real scheduler priority: set np0 as the highest (np0 is qid)
        bit<32> qid_new_head = np0;
        rotate_priority(standard_metadata.egress_port, (bit<5>)qid_new_head);

        // Mark rotation done in this round
        bit<1> rot_w = (do_rot==1w1) ? 1w1 : rot_done;
        rotation_done.write(0, rot_w);

        // Exit split state
        bit<1> sa_w = (do_rot==1w1) ? 1w0 : split;
        split_active.write(0, sa_w);

        // Reset records (keep AUX as AUX_QID; capacity untouched)
        bit<32> sh_w  = (do_rot==1w1) ? 0      : head_qid;
        bit<32> saq;  split_aux_qid.read(saq, 0);
        bit<32> saq_w = (do_rot==1w1) ? AUX_QID: saq;
        split_head_qid.write(0, sh_w);
        split_aux_qid.write(0, saq_w);
    }

    action dec_software_size_predicated() {
        bit<32> old_sz; queue_size.read(old_sz, (bit<32>)meta.cur_qid);
        bit<1> cond = (meta.left19 > (bit<19>)0 && old_sz > 0) ? 1w1 : 1w0;
        bit<32> new_sz = (cond == 1w1) ? (old_sz - 1) : old_sz;
        queue_size.write((bit<32>)meta.cur_qid, new_sz);
    }

    action do_rotate_next() {
        bit<6> sum = (bit<6>)meta.cur_qid + (bit<6>)1;
        bit<5> next = (sum >= (bit<6>)NUM_QUEUES) ? (bit<5>)0 : (bit<5>)sum;
        rotate_priority(standard_metadata.egress_port, next);
    }

    action noop_rotate() { }

    action rotate_bins_predicated() { }

    apply {
        maybe_rotate_on_cap0();

        read_highest_pri(standard_metadata.egress_port, meta.cur_qid);
        get_queue_length(standard_metadata.egress_port, meta.cur_qid, meta.left19);

        dec_software_size_predicated();

        // If taking one out makes it empty (left == 1), rotate; otherwise do not rotate
        if (meta.left19 == (bit<19>)1) {
            do_rotate_next();
        } else {
            noop_rotate();
        }

        // Bucket rotation is time-driven now (no-op here)
        rotate_bins_predicated();

        // Export current sizes for debugging/telemetry
        bit<32> q0; pri2qid.read(q0, 0);
        bit<32> q1; pri2qid.read(q1, 1);
        bit<32> q2; pri2qid.read(q2, 2);
        bit<32> q3; pri2qid.read(q3, 3);
        bit<32> q4; pri2qid.read(q4, 4);

        queue_size.read(meta.size0, q0);
        queue_size.read(meta.size1, q1);
        queue_size.read(meta.size2, q2);
        queue_size.read(meta.size3, q3);
        queue_size.read(meta.size4, q4);
    }
}

/************** Verify / Compute Checksum ******/
control MyVerifyChecksum(inout headers hdr, inout metadata meta) { apply { } }

control MyComputeChecksum(inout headers hdr, inout metadata meta) {
    apply {
        update_checksum(
            hdr.ipv4.isValid(),
            { hdr.ipv4.version,
              hdr.ipv4.ihl,
              hdr.ipv4.diffserv,
              hdr.ipv4.totalLen,
              hdr.ipv4.identification,
              hdr.ipv4.flags,
              hdr.ipv4.fragOffset,
              hdr.ipv4.ttl,
              hdr.ipv4.protocol,
              hdr.ipv4.srcAddr,
              hdr.ipv4.dstAddr },
            hdr.ipv4.hdrChecksum,
            HashAlgorithm.csum16);
    }
}

/************** Deparser ******/
control MyDeparser(packet_out packet, in headers hdr) {
    apply {
        packet.emit(hdr.ethernet);
        packet.emit(hdr.ipv4);
        packet.emit(hdr.icmp);
    }
}

/************** Main ******/
V1Switch(
    MyParser(),
    MyVerifyChecksum(),
    MyIngress(),
    MyEgress(),
    MyComputeChecksum(),
    MyDeparser()
) main;
