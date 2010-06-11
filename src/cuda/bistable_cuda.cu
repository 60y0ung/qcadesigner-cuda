/* ========================================================================== */
/*                                                                            */
/*  CUDA_bistable_iteration.cu                                                */
/*    0- controllare che non vi siano scritte delle porcate da me medesimo*/
/*  1- valutare possibilitÓ di unrollare il loop sui neighbours               */
/*  (visto che ne stabiliamo il numero di iterazioni a priori)                */
/*  2- il controllo sulle celle fixed crea una bella divergenza... proposte?  */
/*  3- 19maggio: clock_data troooppo grande
/*  --> meglio farsi una memcpy ogni sample di clock_data[4] e d_polarization
	con i nuovi valori di polarizzazione degli input (ancora DA MODIFICARE!)
					*/
/* ========================================================================== */
//#define CUPRINTF_B

#include <cutil_inline.h>
#include <cuda.h>

#ifdef CUPRINTF_B
#include "cuPrintf.cu"
#endif //CUPRINTF_B

#include <time.h>
extern "C"{
#include "../coloring/coloring.h"
}
#include <math.h>

#define BLOCK_DIM 256
#undef CLAMP
#define CLAMP(value,low,high) ((value > high) ? high : ((value < low) ? low : value))
#undef PI
#define PI  3.14159265358979323846
#undef FOUR_PI
#define FOUR_PI 12.56637061

__device__ __constant__ double d_clock_prefactor;
__device__ __constant__ double d_clock_shift;
__device__ __constant__ int d_cells_number;
__device__ __constant__ int d_neighbours_number;
__device__ __constant__ int d_input_number;
__device__ __constant__ int d_output_number;
__device__ __constant__ int d_number_of_samples;
__device__ __constant__ double d_clock_low;
__device__ __constant__ double d_clock_high;


__device__ inline int find(int x, int *array, int length)
{
	int l = 0, r = length - 1, mid;
	while (l <= r)
	{
		mid = (l + r) / 2;
		if (array[mid] == x) return mid;
		else if (array[mid] > x) r = mid - 1;
		else l = mid + 1;
	}
	return -1;
}


__global__ void update_inputs (double *d_polarization, int *d_input_indexes, int sample)
{
	extern	__shared__ int shm_array[];
	int i=0,j=d_input_number-1,input_idx;
	int thr_idx = blockIdx.x * blockDim.x + threadIdx.x;
	
	if (threadIdx.x < d_input_number)
	{
		shm_array[threadIdx.x] = d_input_indexes[threadIdx.x];
	}
	__syncthreads();
	
	//find input index and update it
	while (i <= j)
	{
		input_idx = (i + j) / 2;
		if (shm_array[input_idx] == thr_idx)
			d_polarization[thr_idx]=(-1 * __sinf(((double)( 1 << input_idx)) * __fdividef((double)sample * 4.0 * PI ,(double) d_number_of_samples)) > 0) ? 1: -1;
		else if (shm_array[input_idx] > thr_idx) j = input_idx - 1;
		else i = input_idx + 1;
	}
}


__global__ void bistable_kernel (
		double *d_polarization,
		/*double *d_next_polarization,*/
		int *d_cell_clock,
		double *d_Ek,
		int *d_neighbours,
		int sample,
		int *d_output_indexes,
		int *d_stability,
		double tolerance,
		double *d_output_data,
		int *d_cells_colors,
		int color
		)
{
	extern	__shared__ int shm_array[];
	int thr_idx = blockIdx.x * blockDim.x + threadIdx.x;   // Thread index
	int nb_idx;   // Neighbour index
	int q;
	int current_cell_clock;   //could be 0, 1, 2 or 3
	double new_polarization;
	double polarization_math;
	double clock_value;
	int output_idx;
	int stable;
	int *shm_output_indexes = shm_array;
	
	if (threadIdx.x < d_output_number)
	{
		shm_output_indexes[threadIdx.x] = d_output_indexes[threadIdx.x];
	}

	__syncthreads();

	// Only useful threads must work
	if (thr_idx < d_cells_number)
	{		
		//cuPrintf("GO! my_color:%d\n",color);
		//cuPrintf("\nd_output_number = %d,\t d_output_indexes[0]=%d\n",d_output_number, d_output_indexes[0] );	
		  
		//cuPrintf("%f ", d_polarization[thr_idx]);	

		if (!(d_neighbours[thr_idx] == -1) && color == d_cells_colors[thr_idx]) // if thr_idx corresponding cell type is not FIXED or INPUT and is my turn
		{
			nb_idx = 0;
			polarization_math = 0;
			current_cell_clock  = d_cell_clock[thr_idx];

			
			for(q = 0; q < d_neighbours_number & nb_idx != -1; q++)
			{
				nb_idx = d_neighbours[thr_idx + q * d_cells_number];
				if (nb_idx != -1) 
				{
					//kink = d_Ek[thr_idx + q*d_cells_number];
					polarization_math += d_Ek[thr_idx + q*d_cells_number] * d_polarization[nb_idx];
				}
			}

			//math = math / 2 * gamma
			clock_value = d_clock_prefactor * __cosf (((double)(1 << d_input_number)) * __fdividef((double)sample * 4.0 * PI , (double)d_number_of_samples) - __fdividef(PI * current_cell_clock , 2)) + d_clock_shift;
			clock_value = CLAMP(clock_value,d_clock_low,d_clock_high);
			polarization_math = __fdividef(polarization_math,(2.0 * clock_value));
			 
			// -- calculate the new cell polarization -- //
			// if math < 0.05 then math/sqrt(1+math^2) ~= math with error <= 4e-5
			// if math > 100 then math/sqrt(1+math^2) ~= +-1 with error <= 5e-5
			new_polarization =
			(polarization_math        >  1000.0)   ?  1                 :
			(polarization_math        < -1000.0)   ? -1                 :
			(fabs (polarization_math) <     0.001) ?  polarization_math :
			__fdividef(polarization_math , sqrt (1 + polarization_math * polarization_math)) ;
			
			stable = (fabs (new_polarization - d_polarization[thr_idx]) <= tolerance);
			d_stability[thr_idx] = stable;

			//set the new polarization in next_polarization array  
			//d_next_polarization[thr_idx] = new_polarization;
			d_polarization[thr_idx] = new_polarization; //There is no conflicts because there is no read from other thread on this (they have other colors)

			// If any cells polarization has changed beyond this threshold
			// then the entire circuit is assumed to have not converged.      

			output_idx = find(thr_idx, shm_output_indexes, d_output_number);

			if (output_idx >= 0)
			{
				d_output_data[output_idx] = new_polarization;
			}
		}
		/*else
		{
			d_next_polarization[thr_idx] = d_polarization[thr_idx];
		}*/
	}
}

__host__ void swap_arrays(double **array_1, double **array_2)
{
	double *temp = *array_1;
	*array_1 = *array_2;
	*array_2 = temp;
}
   
extern "C"
void launch_bistable_simulation(
	double *h_polarization,
	double *h_Ek,
	int *h_cell_clock,
	int *h_neighbours,
	int cells_number,
	int neighbours_number,
	int number_of_samples,
	int max_iterations,
	int *input_indexes,
	int input_number,
	int *output_indexes,
	int output_number,
	double clock_prefactor,
	double clock_shift,
	double clock_low,
	double clock_high, 
	double tolerance,
	double ***output_traces
	)
{


	// Variables
	double /**d_next_polarization,*/ *d_polarization, *d_Ek;
	int *d_neighbours, *d_cell_clock, *d_input_indexes, *d_output_indexes;
	int i,j,stable,color, num_colors;
	int *d_stability, *h_stability, *h_cells_colors, *d_cells_colors;
	int count;
	int k;
	double *d_output_data;
	double *h_output_data;
	int old_percentage = 0, new_percentage;
	int input_indexes_bytes = sizeof(int)*input_number;
	int output_indexes_bytes = sizeof(int)*output_number;
	int total_iterations = 0;

	
	/*printf("\ntesting launch parameters:\n cells_number = %d\n neighbours_number = %d \n number_of_samples = %d\n max_iterations = %d\n, tolerance = %e\npref: %e, shift: %e, low: %e, high: %e\n",cells_number, neighbours_number, number_of_samples, max_iterations, tolerance,clock_prefactor,clock_shift,clock_low,clock_high);
	printf("output_number = %d, output_indexes[0]= %d\n", output_number , output_indexes[0]);*/


	h_output_data = (double *) malloc(sizeof(double) * output_number);
	h_stability = (int *)malloc(sizeof(int)*cells_number);
	
	//coloring
	
	fprintf(stderr,"Coloring...\n");
	color_graph(h_neighbours, cells_number, neighbours_number, &h_cells_colors, &num_colors);
	fprintf(stderr,"...colored!\n");
	
	printf("Number of samples:%d\nNumber of colors:%d\n",number_of_samples, num_colors);
	
	// Set GPU Parameters
	

	dim3 threads (BLOCK_DIM);
	dim3 grid (ceil ((double)cells_number/BLOCK_DIM));

	// Set Devices
	//cudaSetDevice (cutGetMaxGflopsDeviceId());

#ifdef CUPRINTF_B
	cudaPrintfInit ();
#endif

	//starting timer
	timespec startTime, endTime;
	clock_gettime(CLOCK_REALTIME, &startTime);

	fprintf(stderr,"Allocating memory on device...\n");
	// Initialize Memory
	cutilSafeCall (cudaMalloc ((void**)&d_output_data, output_number * sizeof(double)));
	/*cutilSafeCall (cudaMalloc ((void**)&d_next_polarization, cells_number * sizeof(double)));*/
	cutilSafeCall (cudaMalloc ((void**)&d_polarization, cells_number * sizeof(double))); 
	cutilSafeCall (cudaMalloc ((void**)&d_Ek, sizeof(double)*neighbours_number*cells_number));
	cutilSafeCall (cudaMalloc ((void**)&d_cell_clock, cells_number * sizeof(int)));
	cutilSafeCall (cudaMalloc ((void**)&d_neighbours, sizeof(int)*neighbours_number*cells_number));
	cutilSafeCall (cudaMalloc ((void**)&d_input_indexes, sizeof(int)*input_number));
	cutilSafeCall (cudaMalloc ((void**)&d_output_indexes, sizeof(int)*output_number));
	cutilSafeCall (cudaMalloc ((void**)&d_stability, sizeof(int)*cells_number));
	cutilSafeCall (cudaMalloc ((void**)&d_cells_colors, sizeof(int)*cells_number));
	
	fprintf(stderr,"CudaMalloc done!\n");
	// Set Memory

	/*cutilSafeCall (cudaMemcpy (d_next_polarization, h_polarization, cells_number * sizeof(double), cudaMemcpyHostToDevice));*/
	cutilSafeCall (cudaMemcpy (d_polarization, h_polarization, cells_number * sizeof(double), cudaMemcpyHostToDevice));
	cutilSafeCall (cudaMemcpy (d_Ek, (double *)h_Ek, sizeof(double) * neighbours_number * cells_number, cudaMemcpyHostToDevice));
	cutilSafeCall (cudaMemcpy (d_cell_clock, h_cell_clock, cells_number * sizeof(int), cudaMemcpyHostToDevice));
	cutilSafeCall (cudaMemcpy (d_neighbours, h_neighbours, sizeof(int) * neighbours_number * cells_number, cudaMemcpyHostToDevice));
	cutilSafeCall (cudaMemcpy (d_input_indexes, input_indexes, sizeof(int)*input_number, cudaMemcpyHostToDevice));
	cutilSafeCall (cudaMemcpy (d_output_indexes, output_indexes, sizeof(int)*output_number, cudaMemcpyHostToDevice));
	cutilSafeCall (cudaMemcpy (d_cells_colors, h_cells_colors, sizeof(int)*cells_number, cudaMemcpyHostToDevice));

	fprintf(stderr, "CudaMemcpy done!\n");

	cutilSafeCall (cudaMemcpyToSymbol("d_clock_prefactor", &(clock_prefactor), sizeof(double), 0, cudaMemcpyHostToDevice));
	cutilSafeCall (cudaMemcpyToSymbol("d_clock_shift", &(clock_shift), sizeof(double), 0, cudaMemcpyHostToDevice));
	cutilSafeCall (cudaMemcpyToSymbol("d_cells_number", &(cells_number), sizeof(int), 0, cudaMemcpyHostToDevice));
	cutilSafeCall (cudaMemcpyToSymbol("d_neighbours_number", &(neighbours_number), sizeof(int), 0, cudaMemcpyHostToDevice));
	cutilSafeCall (cudaMemcpyToSymbol("d_input_number", &(input_number), sizeof(int), 0, cudaMemcpyHostToDevice));
	cutilSafeCall (cudaMemcpyToSymbol("d_output_number", &(output_number), sizeof(int), 0, cudaMemcpyHostToDevice));
	cutilSafeCall (cudaMemcpyToSymbol("d_number_of_samples", &(number_of_samples), sizeof(double), 0, cudaMemcpyHostToDevice));
	cutilSafeCall (cudaMemcpyToSymbol("d_clock_low", &(clock_low), sizeof(double), 0, cudaMemcpyHostToDevice));
	cutilSafeCall (cudaMemcpyToSymbol("d_clock_high", &(clock_high), sizeof(double), 0, cudaMemcpyHostToDevice));
	
	fprintf(stderr,"...memory allocated!\nSimulation started...\n");

	for (j = 0; j < number_of_samples; j++)
	{

		stable = 0;
		
		update_inputs<<< grid, threads,input_indexes_bytes>>> (d_polarization, d_input_indexes, j);
		cudaThreadSynchronize ();
		
		
	
		// In each sample...
		for (i = 0; i < max_iterations && !stable; i++)
		{
				
			// Launch Kernel
			for(color = 1; color <= num_colors; color++)
			{
				/*cutilSafeCall(cudaMemcpy(h_polarization,d_polarization,cells_number*sizeof(double),cudaMemcpyDeviceToHost));
				for (k=0;k<cells_number;k++) printf("i:%d, col:%d, cell:%d\t%e\n",i,color,k,h_polarization[k]);*/
				
				bistable_kernel<<< grid, threads, output_indexes_bytes >>> (d_polarization, /*d_next_polarization,*/ d_cell_clock, d_Ek, d_neighbours, 
					j, d_output_indexes, d_stability, tolerance, d_output_data, d_cells_colors, color);
					
				// Wait Device
				cudaThreadSynchronize ();
				
				// Set Memory for the next iteration
				//			cutilSafeCall (cudaMemcpy (d_polarization, d_next_polarization, cells_number * sizeof(double), cudaMemcpyDeviceToDevice));
				/*swap_arrays(&d_polarization,&d_next_polarization);// same array*/
			}
			//	for (count = 0; count<cells_number; count++) printf("%d",h_stability[count]);
			//	printf("\n");

			
			
			cutilSafeCall (cudaMemcpy (h_stability, d_stability, cells_number*sizeof(int), cudaMemcpyDeviceToHost));

			count = 0;
			stable = 1;
			while (count<cells_number && h_stability[count] != 0) count++;
			if (count < cells_number) stable = 0;

	//	  	printf("stabilitÓ: %d,max_iter: %d",stable,max_iterations);

			/*cutilSafeCall (cudaMemcpy (h_polarization, d_polarization, cells_number*sizeof(double), cudaMemcpyDeviceToHost));
			for (count=0; count<20; count++) printf("%e\t",h_polarization[count]);
			printf("\n");*/


			
		}
		
		total_iterations += i;
		
		// Get desidered iteration results from GPU
		cutilSafeCall (cudaMemcpy (h_output_data, d_output_data, output_number * sizeof(double), cudaMemcpyDeviceToHost));

		for (k=0;k<output_number;k++)
		{
			//printf("%e\n", h_output_data[k]); //maybe %lf now that we use double
			(*output_traces)[k][j] = h_output_data[k];
		}

		new_percentage = j*100/number_of_samples;
		if( new_percentage != old_percentage) 
		{
			fprintf(stderr,"\r#Simulating: %d%%",new_percentage);
			fflush(stderr);
		}
		old_percentage = new_percentage;
	}
	
	printf("Iterations per sample: %f\n", (double)total_iterations/number_of_samples);
	
	fprintf(stderr,"\r#Simulating: 100%%!\n");
#ifdef CUPRINTF_B
	cudaPrintfDisplay(stdout, true);
	cudaPrintfEnd();
#endif //CUPRINTF_B



	// Free-up resources
	cudaFree(d_output_data);
//	cudaFree(d_next_polarization);
	cudaFree(d_input_indexes);
	cudaFree(d_output_indexes);
	cudaFree(d_polarization);
	cudaFree(d_cell_clock);
	cudaFree(d_stability);
	cudaFree(d_Ek);
	cudaFree(d_neighbours);
	cudaFree(d_cells_colors);


	//get time result	
	clock_gettime(CLOCK_REALTIME, &endTime);
		timespec temp;
	if ((endTime.tv_nsec-startTime.tv_nsec)<0)
	{
		temp.tv_sec = endTime.tv_sec-startTime.tv_sec-1;
		temp.tv_nsec = 1000000000+endTime.tv_nsec-startTime.tv_nsec;
	} 
	else
	{
		temp.tv_sec = endTime.tv_sec-startTime.tv_sec;
		temp.tv_nsec = endTime.tv_nsec-startTime.tv_nsec;
	}

	fprintf(stdout, "\tProcessing time1: %f (s)\n", (double)temp.tv_sec);

	fprintf(stdout, "\tProcessing time2: %f (ns)\n", (double)temp.tv_nsec);
}
#undef CUPRINTF_B
