/**
 * Declarations of the algorithms implemented using Totem
 *
 *  Created on: 2013-03-24
 *  Author: Abdullah Gharaibeh
 */
#ifndef TOTEM_ALG_H
#define TOTEM_ALG_H

// totem includes
#include "totem_comdef.h"

/**
 * A type for bfs cost. This is useful to allow changes in size.
 */
typedef uint16_t cost_t;
const cost_t INF_COST = (cost_t)INFINITE;

/**
 * A type for page rank. This is useful to allow changes in precision.
 */
typedef float rank_t;

/**
 * Used to define the number of rounds: a static convergance condition
 * for PageRank
 */
const int PAGE_RANK_ROUNDS = 30;

/**
 * A probability used in the PageRank algorithm that models the behavior of the 
 * random surfer when she moves from one page to another without following the 
 * links on the current page.
 * TODO(abdullah): The variable could be passed as a parameter in the entry
 * function to enable more flexibility and experimentation. This however 
 * increases register usage and may affect performance
 */
const double PAGE_RANK_DAMPING_FACTOR = 0.85;

/**
 * Specifies a type for centrality scores. This is useful to allow future
 * changes in the precision and value range that centrality scores can hold.
 */
typedef float score_t;

/**
 * The Centrality algorithms accepts an epsilon value to determine the amount
 * of error that is tolerable, along with how long the algorithm will take to
 * complete. A value of 0.0 will indicate that the algorithm should compute an
 * exact metric. For approximate Betweenness Centrality, we are currently using
 * a value of 1.0, which could change. This value was initially selected as it
 * allows the algorithm to complete in a more reasonable amount of time.
 */
const double CENTRALITY_EXACT = 0.0;
const double CENTRALITY_APPROXIMATE = 1.0;


/**
 * Given an undirected, unweighted graph and a source vertex, find the minimum
 * number of edges needed to reach every vertex V from the source vertex.
 * Its implementation follows Breadth First Search variation based on
 * in [Harish07] using the CPU and GPU, respectively.
 *
 * @param[in]  graph  the graph to perform BFS on
 * @param[in]  src_id id of the source vertex
 * @param[out] cost   the distance (number of of hops) of each vertex from the
 *                    source
 * @return generic success or failure
*/
error_t bfs_cpu(graph_t* graph, vid_t src_id, cost_t* cost);
error_t bfs_queue_cpu(graph_t* graph, vid_t source_id, cost_t* cost);
error_t bfs_gpu(graph_t* graph, vid_t src_id, cost_t* cost);
error_t bfs_vwarp_gpu(graph_t* graph, vid_t src_id, cost_t* cost);
error_t bfs_hybrid(vid_t src_id, cost_t* cost);

/**
 * Given a weighted graph \f$G = (V, E, w)\f$ and a source vertex \f$v\inV\f$,
 * Dijkstra's algorithm computes the distance from \f$v\f$ to every other
 * vertex in a directed, weighted graph, where the edges have non-negative
 * weights (i.e., \f$\forall (u,v) \in E, w(u,v) \leq 0\f$).
 *
 * @param[in] graph an instance of the graph structure
 * @param[in] source_id vertex id for the source
 * @param[out] shortest_distances the length of the computed shortest paths
 * @return generic success or failure
 */
error_t dijkstra_cpu(const graph_t* graph, vid_t src_id, weight_t* distance);
error_t dijkstra_gpu(const graph_t* graph, vid_t src_id, weight_t* distance);
error_t dijkstra_vwarp_gpu(const graph_t* graph, vid_t src_id,
                           weight_t* distance);

/**
 * Given a weighted graph \f$G = (V, E, w)\f$, the All Pairs Shortest Path
 * algorithm computes the distance from every vertex to every other vertex
 * in a weighted graph with no negative cycles.
 *
 * @param[in] graph an instance of the graph structure
 * @param[out] path_ret the length of the computed shortest paths for each
 *                      vertex
 * @return generic success or failure
 */
error_t apsp_cpu(graph_t* graph, weight_t** path_ret);
error_t apsp_gpu(graph_t* graph, weight_t** path_ret);

/**
 * Implements a version of the simple PageRank algorithm described in
 * [Malewicz 2010] for both CPU and CPU. Algorithm details are described in
 * totem_page_rank.cu. Note that the "incoming" postfixed funtions take into
 * consideration the incoming edges, while the first two consider the outgoing
 * edges.
 * @param[in]  graph the graph to run PageRank on
 * @param[in]  rank_i the initial rank for each node in the graph (NULL
 *                    indicates uniform initial rankings as default)
 * @param[out] rank the PageRank output array (must be freed via mem_free)
 * @return generic success or failure
 */
error_t page_rank_cpu(graph_t* graph, float* rank_i, float* rank);
error_t page_rank_gpu(graph_t* graph, float* rank_i, float* rank);
error_t page_rank_vwarp_gpu(graph_t* graph, float* rank_i, float* rank);
error_t page_rank_incoming_cpu(graph_t* graph, float* rank_i, float* rank);
error_t page_rank_incoming_gpu(graph_t* graph, float* rank_i, float* rank);
error_t page_rank_hybrid(float* rank_i, float* rank);
error_t page_rank_incoming_hybrid(float* rank_i, float* rank);


/**
 * Implements the push-relabel algorithm for determining the Maximum flow
 * through a directed graph for both the CPU and the GPU, as described in
 * Hong08]. Note that the source graph must be a flow network, that is, for
 * every edge (u,v) in the graph, there must not exist an edge (v,u).
 *
 * @param[in]  graph the graph on which to run Max Flow
 * @param[in]  source_id the id of the source vertex
 * @param[in]  sink_id the id of the sink vertex
 * @param[out] flow_ret the maximum flow through the network
 * @return generic success or failure
 */
error_t maxflow_cpu(graph_t* graph, vid_t source_id, vid_t sink_id,
                    weight_t* flow_ret);
error_t maxflow_gpu(graph_t* graph, vid_t source_id, vid_t sink_id,
                    weight_t* flow_ret);
error_t maxflow_vwarp_gpu(graph_t* graph, vid_t source_id, vid_t sink_id,
                          weight_t* flow_ret);

/**
 * Given a weighted and undirected graph, the algorithm identifies for each
 * vertex the largest p-core it is part of. A p-core is the maximal subset of
 * vertices such that the sum of edge weights each vertex has is at least "p".
 * The word maximal means that there is no other vertex in the graph that can
 * be added to the subset while preserving the aforementioned property.
 * Note that p-core is a variation of the k-core concept: k-core considers
 * degree, while p-core considers edge weights. If all edges have weight 1, then
 * p-core becomes k-core.
 * Specifically, the algorithm computes the p-core for a range of "p" values
 * between "start" and the maximum p the graph has. In each round, "p" is
 * incremented by "step". The output array "round" stores the latest round
 * (equivalent to the highest p-core) a vertex was part of.
 *
 * @param[in] graph an instance of the graph structure
 * @param[in] start the start value of p
 * @param[in] step the value used to increment p in each new round
 * @param[out] round for each vertex  latest round a vertex was part of
 * @return generic success or failure.
 */
error_t pcore_cpu(const graph_t* graph, uint32_t start, uint32_t step,
                  uint32_t** round);

error_t pcore_gpu(const graph_t* graph, uint32_t start, uint32_t step,
                  uint32_t** round);


/**
 * Given an [un]directed, unweighted graph, a source vertex, and a destination
 * vertex. Check if the destination is reachable from the source using the CPU
 * and GPU, respectively.
 * @param[in] source_id id of the source vertex
 * @param[in] destination_id id of the destination vertex
 * @param[in] graph the graph to perform BFS on
 * @param[out] connected true if destination is reachable from source;
 *             otherwise, false.
 * @return generic success or failure.
*/
error_t stcon_cpu(const graph_t* graph, vid_t source_id, vid_t destination_id,
                  bool* connected);

error_t stcon_gpu(const graph_t* graph, vid_t source_id, vid_t destination_id,
                  bool* connected);

/**
 * Given a graph, count the number of edges leaving each node.
 * @param[in] graph the graph to use
 * @param[out] node_degree pointer to output list of node degrees, indexed by
 *             vertex id
 * @return generic success or failure.
*/
error_t node_degree_cpu(const graph_t* graph, uint32_t** node_degree);
error_t node_degree_gpu(const graph_t* graph, uint32_t** node_degree);

/**
 * Calculate betweenness centrality scores for unweighted graphs using the
 * successors stack implementation.
 * @param[in] graph the graph to use
 * @param[out] centrality_score the output list of betweenness centrality scores
 *             per vertex
 * @return generic success or failure
 */
error_t betweenness_unweighted_cpu(const graph_t* graph,
                                   score_t* centrality_score);
error_t betweenness_unweighted_gpu(const graph_t* graph,
                                   score_t* centrality_score);

/**
 * Calculate betweenness centrality scores for unweighted graphs using the
 * predecessors map implementation.
 * @param[in] graph the graph to use
 * @param[out] centrality_score the output list of betweenness centrality scores
 *             per vertex
 * @return generic success or failure
 */
error_t betweenness_unweighted_shi_gpu(const graph_t* graph,
                                       score_t* centrality_score);

/**
 * Calculate betweenness centrality scores for graphs using the algorithm
 * described in Chapter 2 of GPU Computing Gems (Algorithm 1)
 * @param[in] graph the graph for which the centrality measure is calculated
 * @param[in] epsilon determines how precise the results of the algorithm will
 *            be, and thus also how long it will take to compute
 * @param[out] centrality_score the output list of betweenness centrality
 *             scores per vertex
 * @return generic success or failure
 */
error_t betweenness_cpu(const graph_t* graph, double epsilon, 
                        score_t* centrality_score);
error_t betweenness_gpu(const graph_t* graph, double epsilon, 
                        score_t* centrality_score);

/**
 * Implements the parallel Brandes closeness centrality algorithm using
 * predecessor maps as described in "Fast Network Centrality Analysis Using
 * GPUs" [Shi11]
 */
error_t closeness_unweighted_cpu(const graph_t* graph,
                                 weight_t** centrality_score);
error_t closeness_unweighted_gpu(const graph_t* graph,
                                 weight_t** centrality_score);

/**
 * Calculate stress centrality scores for unweighted graphs.
 * @param[in] graph the graph
 * @param[out] centrality_score the output list of stress centrality scores  for
 *                              each vertex
 * @return generic success or failure
 */
error_t stress_unweighted_cpu(const graph_t* graph,
                              weight_t** centrality_score);
error_t stress_unweighted_gpu(const graph_t* graph,
                              weight_t** centrality_score);

#endif  // TOTEM_ALG_H