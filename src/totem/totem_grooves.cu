/**
 * Implements the Grooves interface.
 *
 *  Created on: 2012-01-25
 *  Author: Abdullah Gharaibeh
 */

// totem includes
#include "totem_comkernel.cuh"
#include "totem_grooves.h"
#include "totem_mem.h"
#include "totem_partition.h"

PRIVATE void init_get_remote_nbrs(partition_t* partition, int pid, 
                                  uint32_t vertex_count, uint32_t pcount, 
                                  id_t** nbrs, uint32_t** count_per_par) {
  graph_t* subgraph = &(partition->subgraph);

  // This is a temporary hash table to identify the remote neighbors.
  // It is initialized with conservative space such that it can accommodate
  // the extreme case where all vertices in other partitions are remote to
  // this partition
  hash_table_t* ht;
  CALL_SAFE(hash_table_initialize_cpu(vertex_count - subgraph->vertex_count, 
                                      &ht));
  *count_per_par = (uint32_t*)calloc(pcount - 1, sizeof(uint32_t));
  for (id_t vid = 0; vid < subgraph->vertex_count; vid++) {
    for (id_t i = subgraph->vertices[vid];
         i < subgraph->vertices[vid + 1]; i++) {
      id_t nbr = subgraph->edges[i];
      int nbr_pid = GET_PARTITION_ID(nbr);
      if (nbr_pid != pid) {
        partition->rmt_edge_count++;
        bool found;
        HT_CHECK(ht, nbr, found);
        if (!found) {
          CALL_SAFE(hash_table_put_cpu(ht, nbr, 1));
          int bindex = GROOVES_BOX_INDEX(nbr_pid, pid, pcount);
          __sync_fetch_and_add(&(*count_per_par)[bindex], 1);
        }
      }
    }
  }
  CALL_SAFE(hash_table_get_keys_cpu(ht, nbrs, &partition->rmt_vertex_count));
  hash_table_finalize_cpu(ht);
}

PRIVATE void init_allocate_table(grooves_box_table_t* btable, uint32_t pid, 
                                 uint32_t pcount, uint32_t* count_per_par) {
  // initialize the outbox hash tables
  for (int remote_pid = (pid + 1) % pcount; remote_pid != pid; 
       remote_pid = (remote_pid + 1) % pcount) {
    int bindex = GROOVES_BOX_INDEX(remote_pid, pid, pcount);
    if (count_per_par[bindex]) {
      CALL_SAFE(hash_table_initialize_cpu(count_per_par[bindex], 
                                          &(btable[bindex].ht)));
    }
  }
}

PRIVATE void init_table_gpu(grooves_box_table_t* btable, uint32_t bcount, 
                            size_t msg_size, grooves_box_table_t** btable_d,
                            grooves_box_table_t** btable_h) {
  *btable_h = (grooves_box_table_t*)calloc(bcount, sizeof(grooves_box_table_t));
  memcpy(*btable_h, btable, bcount * sizeof(grooves_box_table_t));
  // initialize the tables on the gpu  
  for (uint32_t bindex = 0; bindex < bcount; bindex++) {
    hash_table_t hash_table_d;
    if ((*btable_h)[bindex].count) {
      CALL_SAFE(hash_table_initialize_gpu(&((*btable_h)[bindex].ht), 
                                          &hash_table_d));
      (*btable_h)[bindex].ht = hash_table_d;
      CALL_CU_SAFE(cudaMalloc((void**)&((*btable_h)[bindex].values), 
                              (*btable_h)[bindex].count * msg_size));
    }
  }

  // transfer the table array
  CALL_CU_SAFE(cudaMalloc((void**)(btable_d), bcount * 
                          sizeof(grooves_box_table_t)));
  CALL_CU_SAFE(cudaMemcpy(*btable_d, (*btable_h), 
                          bcount * sizeof(grooves_box_table_t), 
                          cudaMemcpyHostToDevice));
}

PRIVATE void init_outbox_table(partition_t* partition, uint32_t pid, 
                               uint32_t pcount, uint32_t* remote_nbrs,
                               size_t msg_size) {
  grooves_box_table_t* outbox = partition->outbox;
  // build the outboxs hash tables
  for (uint32_t i = 0; i < partition->rmt_vertex_count; i++) {
    uint32_t nbr = remote_nbrs[i];
    uint32_t nbr_pid = GET_PARTITION_ID(nbr);
    int bindex = GROOVES_BOX_INDEX(nbr_pid, pid, pcount);
    CALL_SAFE(hash_table_put_cpu(&(outbox[bindex].ht), nbr, 
                                 outbox[bindex].count));
    outbox[bindex].count++;
  }
  // Allocate the values array for the cpu-based partitions. The gpu-based
  // partitions will have their values array allocated later when their
  // state is initialized on the gpu
  if (partition->processor.type == PROCESSOR_GPU) return;
  for (int rpid = 0; rpid < pcount - 1; rpid++) {
    if (outbox[rpid].count) {
      outbox[rpid].values = mem_alloc(outbox[rpid].count * msg_size);
    }
  }
}

PRIVATE void init_outbox(partition_set_t* pset) {
  uint32_t pcount = pset->partition_count;
  for (int pid = 0; pid < pcount; pid++) {
    partition_t* partition = &pset->partitions[pid];

    // each remote partition has a slot in the outbox array
    partition->outbox = 
      (grooves_box_table_t*)calloc(pcount - 1, sizeof(grooves_box_table_t));

    if (!partition->subgraph.vertex_count || 
        !partition->subgraph.edge_count) continue;

    // identify the remote nbrs and their count per remote partition
    id_t*     remote_nbrs   = NULL;
    uint32_t* count_per_par = NULL;
    init_get_remote_nbrs(partition, pid, pset->graph->vertex_count, pcount,
                         &remote_nbrs, &count_per_par);

    // build the outbox
    if (partition->rmt_vertex_count) {
      assert(remote_nbrs && count_per_par);
      // initialize the outbox hash tables
      init_allocate_table(partition->outbox, pid, pcount, count_per_par);
      // build the outbox hash tables
      init_outbox_table(partition, pid, pcount, remote_nbrs, pset->msg_size);
      free(remote_nbrs);
      free(count_per_par);
    }
  }
}

PRIVATE void init_inbox(partition_set_t* pset) {
  uint32_t pcount = pset->partition_count;
  for (int pid = 0; pid < pcount; pid++) {
    partition_t* partition = &pset->partitions[pid];

    // each remote partition has a slot in the inbox array
    partition->inbox = 
      (grooves_box_table_t*)calloc(pcount - 1, sizeof(grooves_box_table_t));

    if (!partition->subgraph.vertex_count || 
        !partition->subgraph.edge_count) continue;
    
    for (int src_pid = (pid + 1) % pcount; src_pid != pid; 
         src_pid = (src_pid + 1) % pcount) {
      partition_t* remote_par = &pset->partitions[src_pid];
      // An inbox in a partition is an outbox in the source partition. 
      // Therefore, we just need to copy the state of the already built
      // source partition's outbox into the destination partition's inbox.
      // This includes copying a reference to the hash table that maintains
      // the set of boundary vertices (vertices that belong to this partition, 
      // and are the destination of a remote edge that originates in another 
      // partition, and are maintained in the outbox of that other partition).
      int src_bindex = GROOVES_BOX_INDEX(pid, src_pid, pcount);
      int dst_bindex = GROOVES_BOX_INDEX(src_pid, pid, pcount);      
      partition->inbox[dst_bindex] = remote_par->outbox[src_bindex];
      if (remote_par->processor.type == PROCESSOR_GPU) {
        // if the remote processor is GPU, then a values array for this inbox
        // needs to be allocated on the host
        partition->inbox[dst_bindex].values = 
          mem_alloc(partition->inbox[dst_bindex].count * pset->msg_size);
      }
    }
  }
}

PRIVATE void init_gpu_enable_peer_access(uint32_t pid, partition_set_t* pset) {
  uint32_t pcount = pset->partition_count;
  partition_t* partition = &pset->partitions[pid];
  for (int remote_pid = (pid + 1) % pcount; remote_pid != pid; 
       remote_pid = (remote_pid + 1) % pcount) {
    partition_t* remote_par = &pset->partitions[remote_pid];
    if (remote_par->processor.type == PROCESSOR_GPU &&
        remote_par->processor.id != partition->processor.id) {
      CALL_CU_SAFE(cudaDeviceEnablePeerAccess(remote_par->processor.id, 0));
    }
  }
}

PRIVATE void init_gpu_state(partition_set_t* pset) {
  uint32_t pcount = pset->partition_count;

  // The following array will maintain pointers to the gpu-partitions' ouboxes
  // state on the host after they are copied to the gpu. These references are 
  // maintained in order to free their state safely.
  // Outboxes are shared by the destination partitions as an inbox. Outboxes
  // that are shared between a gpu partition and a cpu one will not be freed. It
  // will be freed at finalization as part of finalizing the inboxes of the 
  // destination cpu partition. However, outboxes shared between two gpu 
  // partitions will be freed right after they are copied to the gpu (they will 
  // be copied once as an outbox in the source partitions and as an inbox to the
  // destination).
  grooves_box_table_t** host_outboxes = 
    (grooves_box_table_t**)calloc(pcount, sizeof(grooves_box_table_t*));

  for (int pid = 0; pid < pcount; pid++) {
    partition_t* partition = &pset->partitions[pid];
    if (partition->processor.type == PROCESSOR_GPU) {
      // set device context, create the streams and the tables for this gpu
      CALL_CU_SAFE(cudaSetDevice(partition->processor.id));
      CALL_CU_SAFE(cudaStreamCreate(&partition->streams[0]));
      CALL_CU_SAFE(cudaStreamCreate(&partition->streams[1]));
      grooves_box_table_t* outbox_h = NULL;
      init_table_gpu(partition->outbox, pcount - 1, pset->msg_size, 
                     &partition->outbox_d, &outbox_h);
      host_outboxes[pid] = partition->outbox;
      partition->outbox = outbox_h;

      grooves_box_table_t* inbox_h = NULL;
      init_table_gpu(partition->inbox, pcount - 1, pset->msg_size, 
                     &partition->inbox_d, &inbox_h);
      free(partition->inbox);
      partition->inbox = inbox_h;
      init_gpu_enable_peer_access(pid, pset);
    }
  }

  // Clean up the state on the host. As mentioned before, only the outboxes
  // that are shared between two gpu-based partitions are freed.
  for (int pid = 0; pid < pcount; pid++) {
    partition_t* partition = &pset->partitions[pid];
    grooves_box_table_t* outbox = host_outboxes[pid];
    if (partition->processor.type == PROCESSOR_GPU) {
      for (int bindex = 0; bindex < pcount - 1; bindex++) {
        partition_t* remote_par = &pset->partitions[(pid + 1 + bindex)%pcount];
        if (remote_par->processor.type == PROCESSOR_GPU &&
            outbox[bindex].count) {
          hash_table_finalize_cpu(&(outbox[bindex].ht));
        }
      }
      free(host_outboxes[pid]);
    }
  }
  free(host_outboxes);
}

error_t grooves_initialize(partition_set_t* pset) {
  if (pset->partition_count > 1) {
    init_outbox(pset);
    init_inbox(pset);
    init_gpu_state(pset);
  }
  return SUCCESS;
}

PRIVATE void finalize_table_gpu(grooves_box_table_t* btable_d, 
                                grooves_box_table_t* btable_h,
                                uint32_t bcount) {
  CALL_CU_SAFE(cudaFree(btable_d));
  // finalize the tables on the gpu
  for (uint32_t bindex = 0; bindex < bcount; bindex++) {
    if (btable_h[bindex].count) {
      hash_table_finalize_gpu(&(btable_h[bindex].ht));
      CALL_CU_SAFE(cudaFree(btable_h[bindex].values));
    }
  }
  free(btable_h);
}

PRIVATE void finalize_gpu_disable_peer_access(uint32_t pid, 
                                              partition_set_t* pset) {
  uint32_t pcount = pset->partition_count;
  partition_t* partition = &pset->partitions[pid];
  for (int remote_pid = (pid + 1) % pcount; remote_pid != pid; 
       remote_pid = (remote_pid + 1) % pcount) {
    partition_t* remote_par = &pset->partitions[remote_pid];
    if (remote_par->processor.type == PROCESSOR_GPU &&
        remote_par->processor.id != partition->processor.id) {
      CALL_CU_SAFE(cudaDeviceDisablePeerAccess(remote_par->processor.id));
    }
  }
}

PRIVATE void finalize_outbox(partition_set_t* pset) {
  uint32_t pcount = pset->partition_count;
  for (int pid = 0; pid < pcount; pid++) {
    partition_t* partition = &pset->partitions[pid];
    assert(partition->outbox);
    if (partition->processor.type == PROCESSOR_GPU) {
      CALL_CU_SAFE(cudaSetDevice(partition->processor.id));
      CALL_CU_SAFE(cudaStreamDestroy(partition->streams[0]));
      CALL_CU_SAFE(cudaStreamDestroy(partition->streams[1]));
      finalize_gpu_disable_peer_access(pid, pset);
      finalize_table_gpu(partition->outbox_d, partition->outbox, pcount - 1);
    } else {
      assert(partition->processor.type == PROCESSOR_CPU);
      for (uint32_t bindex = 0; bindex < pcount - 1; bindex++) {
        if (partition->outbox[bindex].count) {
          hash_table_finalize_cpu(&(partition->outbox[bindex].ht));
          mem_free(partition->outbox[bindex].values);
        }
      }
      free(partition->outbox);
    }
  }
}

PRIVATE void finalize_inbox(partition_set_t* pset) {
  uint32_t pcount = pset->partition_count;
  for (int pid = 0; pid < pcount; pid++) {
    partition_t* partition = &pset->partitions[pid];
    assert(partition->inbox);
    if (partition->processor.type == PROCESSOR_GPU) {
      CALL_CU_SAFE(cudaSetDevice(partition->processor.id));
      finalize_table_gpu(partition->inbox_d, partition->inbox, pcount - 1);
    } else {
      assert(partition->processor.type == PROCESSOR_CPU);
      for (int bindex = 0; bindex < pcount - 1; bindex++) {
        partition_t* remote_par = &pset->partitions[(pid + 1 + bindex)%pcount];
        // free only the inboxes that are the destination of an outbox of a gpu-
        // partition. Others that are destinations to a cpu-partition will be 
        // freed as an outbox in the source partition.
        if (remote_par->processor.type == PROCESSOR_GPU &&
            partition->inbox[bindex].count) {
          hash_table_finalize_cpu(&(partition->inbox[bindex].ht));
          mem_free(partition->inbox[bindex].values);
        }
      }
      free(partition->inbox);
    }
  }
}

error_t grooves_finalize(partition_set_t* pset) {
  if (pset->partition_count > 1) {
    finalize_outbox(pset);
    finalize_inbox(pset);
  }
  return SUCCESS;
}

error_t grooves_launch_communications(partition_set_t* pset) {
  uint32_t pcount = pset->partition_count;
  for (int src_pid = 0; src_pid < pcount; src_pid++) {
    for (int dst_pid = (src_pid + 1) % pcount; dst_pid != src_pid; 
         dst_pid = (dst_pid + 1) % pcount) {
      // if both partitions are on the host, then, by design the source
      // partition's outbox is shared with the destination partition's inbox,
      // hence no need to copy data
      if ((pset->partitions[src_pid].processor.type == PROCESSOR_CPU) &&
          (pset->partitions[dst_pid].processor.type == PROCESSOR_CPU)) continue;

      cudaStream_t* stream = &pset->partitions[src_pid].streams[0];
      grooves_box_table_t* src_box = 
        &pset->partitions[src_pid].outbox[GROOVES_BOX_INDEX(dst_pid, src_pid, 
                                                           pcount)];
      // if the two partitions share nothing, then we have nothing to do
      if (!src_box->count) continue;

      if (pset->partitions[dst_pid].processor.type == PROCESSOR_GPU) {
        stream = &pset->partitions[dst_pid].streams[0];
      }
      grooves_box_table_t* dst_box = 
        &pset->partitions[dst_pid].inbox[GROOVES_BOX_INDEX(src_pid, dst_pid, 
                                                           pcount)];      
      assert(src_box->count == dst_box->count);
      CALL_CU_SAFE(cudaMemcpyAsync(dst_box->values, src_box->values,
                                   dst_box->count * pset->msg_size,
                                   cudaMemcpyDefault, *stream));
    }
  }
  return SUCCESS;
}

error_t grooves_synchronize(partition_set_t* pset) {
  for (int pid = 0; pid < pset->partition_count; pid++) {
    partition_t* partition = &pset->partitions[pid];
    if (partition->processor.type == PROCESSOR_CPU) continue;
    CALL_CU_SAFE(cudaStreamSynchronize(partition->streams[0]));
  }
  return SUCCESS;
}