#include <stdio.h>
#include <stdlib.h>
#include "svmTrain.h"
#include "parse.hpp"
#include <iostream>
#include <cuda_runtime.h>
#include <cublas_v2.h>
#include <cuda.h>
#include <cblas.h>
#include <vector>
#include <string.h>
#include <getopt.h>
#include <math.h>
#include <vector>
#include "CycleTimer.h"
#include "svmTrainMain.hpp"

#include <thrust/host_vector.h> 
#include <thrust/device_vector.h> 
#include <thrust/copy.h> 
#include <thrust/fill.h> 
#include <thrust/sequence.h>
#include <thrust/for_each.h>
#include <thrust/iterator/zip_iterator.h>
#include <thrust/inner_product.h>
#include <thrust/extrema.h>

#define IDX2C(i,j,ld) (((j)*(ld))+(i))

using namespace std;

// Scalars
const float alpha = 1;
const float beta = 0;

//functor for obtaining the I sets
struct arbitrary_functor
{

	const float C; 

	arbitrary_functor(float _c) : C(_c) {}

    template <typename Tuple>
    __host__ __device__
    void operator()(Tuple t)
    {
        // I_set[i] = Alpha[i],  Y[i] , f[i], I_set1[i], I_set2[i];
		if(thrust::get<0>(t) == 0) {
		
			if(thrust::get<1>(t) == 1) {
			
				
				thrust::get<3>(t) = thrust::get<2>(t);
				
			}
			
			else {
				
				thrust::get<4>(t) = thrust::get<2>(t);
				
			}

		}	else if(thrust::get<0>(t) == C) {
		
			if(thrust::get<1>(t) == -1) {
			
				thrust::get<3>(t) = thrust::get<2>(t);
				
			}
			
			else {
				
				thrust::get<4>(t) = thrust::get<2>(t);
				
			}

		}	else {
		
			thrust::get<3>(t) = thrust::get<2>(t);
			thrust::get<4>(t) = thrust::get<2>(t);
			
		}
	}
};

//functor for performing the f_update step in GPU using Thrust
struct update_functor
{
	const float gamma;
	const float alpha_lo_old;
	const float alpha_hi_old;
	const float alpha_lo_new;
	const float alpha_hi_new;
	const int y_lo;
	const int y_hi;
	const float x_hi_sq;
	const float x_lo_sq;

	update_functor(float _gamma, float _alpha_lo_old, float _alpha_hi_old, float _alpha_lo_new, float _alpha_hi_new, int _y_lo, int _y_hi, float _x_hi_sq, float _x_lo_sq) : 

	gamma(_gamma), 
	alpha_lo_old(_alpha_lo_old), 
	alpha_hi_old(_alpha_hi_old), 
	alpha_lo_new(_alpha_lo_new), 
	alpha_hi_new(_alpha_hi_new), 
	y_lo(_y_lo), 
	y_hi(_y_hi),
	x_hi_sq(_x_hi_sq),
	x_lo_sq(_x_lo_sq) 

	{}

    template <typename Tuple>
    __host__ __device__
    void operator()(Tuple t)
    {
		float rbf_hi = expf(-1 * gamma * (thrust::get<2>(t) + x_hi_sq - (2*thrust::get<0>(t)) ));
		//printf("%f\t%f\n" , -1 * gamma * (thrust::get<2>(t) + x_hi_sq - (2*thrust::get<0>(t)) ) , rbf_hi);
		float rbf_lo = expf(-1 * gamma * (thrust::get<2>(t) + x_lo_sq - (2*thrust::get<1>(t)) ));
		//printf("%f\t%f\n" , -1 * gamma * (thrust::get<2>(t) + x_lo_sq - (2*thrust::get<1>(t)) ) , rbf_lo);

		float delta = (((alpha_hi_new-alpha_hi_old)*y_hi*rbf_hi) + ((alpha_lo_new - alpha_lo_old)*y_lo*rbf_lo));
	
		thrust::get<3>(t) += delta;	
	}
};



//cache lookup
thrust::device_vector<float>& SvmTrain::lookup_cache(int I_idx, bool& cache_hit) {

	//static thrust::device_vector<float> g_hi_dotprod (state.num_train_data);
	thrust::device_vector<float>* lookup = lineCache->lookup(I_idx);
	if(lookup != NULL){
		cache_hit = true;
		return *lookup;
	}

	else {
		cache_hit = false;
		return lineCache->get_new_cache_line(I_idx);

	}
}

//Allocate x_hi, x_lo and an empty vector in device	i
void SvmTrain::init_cuda_handles() {

	cublasStatus_t status;
	cudaError_t cudaStat;
	
	status = cublasCreate(&handle);
	
	if (status != CUBLAS_STATUS_SUCCESS) { 

		cout << "CUBLAS initialization failed\n"; 
		exit(EXIT_FAILURE); 
	}

	cudaStat = cudaStreamCreate(&stream1);
	cudaStat = cudaStreamCreate(&stream2);

	if (cudaStat == cudaErrorInvalidValue) { 

		cout << "CUDA stream initialization failed\n"; 
		exit(EXIT_FAILURE); 
	}
	
}

void SvmTrain::destroy_cuda_handles() {

	cublasDestroy(handle);

}


int SvmTrain::update_f(int I_lo, int I_hi, int y_lo, int y_hi, float alpha_lo_old, float alpha_hi_old, float alpha_lo_new, float alpha_hi_new) {

//	unsigned long long t1,t2;
//	t1 = CycleTimer::currentTicks();
	
	//	cout << I_hi << "," << I_lo << "\n";

	//	lineCache -> dump_map_contents();	


	bool hi_hit;
	bool lo_hit;

	thrust::device_vector<float>& g_hi_dotprod  = lookup_cache(I_hi, hi_hit);
	
	float* raw_g_hi_dotprod = thrust::raw_pointer_cast(&g_hi_dotprod[0]);

	//printf("%x, %x\n",raw_g_hi_dotprod, raw_g_lo_dotprod);

	//cout << "UPDATE_F: " << t2-t1 << "\n";
	//t1 = t2;

	if(!hi_hit) {

		//cout << "HI MISS\n";

		cublasSetStream(handle, stream1);

//	t2 = CycleTimer::currentTicks();
//	cout << "UPDATE_F, INIT: " << t2-t1 << "\n";
//	t1 = t2;
		
		cublasSgemv( handle, CUBLAS_OP_T, state.num_attributes, state.num_train_data, &alpha, raw_g_x, state.num_attributes, &raw_g_x[I_hi * state.num_attributes], 1, &beta, raw_g_hi_dotprod, 1 );
	
//	t2 = CycleTimer::currentTicks();
//	cout << "SGEMV 1: " << t2-t1 << "\n";
//	t1 = t2;
	}

	/*cout << "----------------\n";

	for (int i = 100 ; i < 130; i++) {

		cout << g_hi_dotprod[i] << ",";

	}

	cout << "\n-------------\n";*/
	thrust::device_vector<float>& g_lo_dotprod  = lookup_cache(I_lo, lo_hit);
	float* raw_g_lo_dotprod = thrust::raw_pointer_cast(&g_lo_dotprod[0]);
	
	if(!lo_hit) {

		//cout << "LO MISS \n";

		cublasSetStream(handle, stream2);
	
		cublasSgemv( handle, CUBLAS_OP_T, state.num_attributes, state.num_train_data, &alpha, raw_g_x, state.num_attributes, &raw_g_x[I_lo * state.num_attributes], 1, &beta, raw_g_lo_dotprod, 1 );
	
	}

	/*cout << "----------------\n";

	for (int i = 100 ; i < 130; i++) {

		cout << g_lo_dotprod[i] << ",";

	}

	cout << "\n-------------\n";*/

	//printf("G_X_SQ: %x - %x\n", thrust::raw_pointer_cast(&g_x_sq[0]), thrust::raw_pointer_cast(&g_x_sq[state.num_train_data-1]));
	//printf("G_F: %x - %x\n", thrust::raw_pointer_cast(&g_f[0]), thrust::raw_pointer_cast(&g_f[state.num_train_data-1]));
	//printf("G_X_SQ: %x - %x\n", thrust::raw_pointer_cast(&g_x_sq[0]), thrust::raw_pointer_cast(&g_x_sq[state.num_train_data-1]));



	//printf("%x, %x\n", thrust::raw_pointer_cast(&g_hi_dotprod[state.num_attributes-1]), thrust::raw_pointer_cast(&g_lo_dotprod[state.num_attributes-1]));

//	t2 = CycleTimer::currentTicks();
//	cout << "SGEMV 2: " << t2-t1 << "\n";
//	t1 = t2;

	float x_hi_sq = g_x_sq[I_hi];
	float x_lo_sq = g_x_sq[I_lo];
		
	thrust::for_each(thrust::make_zip_iterator(thrust::make_tuple(g_hi_dotprod.begin(), g_lo_dotprod.begin(), g_x_sq.begin(), g_f.begin())),
   	                 thrust::make_zip_iterator(thrust::make_tuple(g_hi_dotprod.end(), g_lo_dotprod.end(), g_x_sq.end(),g_f.end())),
       	             update_functor(state.gamma, alpha_lo_old, alpha_hi_old, alpha_lo_new, alpha_hi_new, y_lo, y_hi, x_hi_sq, x_lo_sq));

	/*cout << "----------------\n";

	for (int i = 100 ; i < 130; i++) {
		
		cout << g_f[i] << ",";

	}
	cout << "\n-------------\n";*/
	//prev_hi = I_hi;
	//prev_lo = I_lo;

//	t2 = CycleTimer::currentTicks();
//	cout << "UPDATE_FUNCTOR: " << t2-t1 << "\n";
//	t1 = t2;

/////////////////////////////////////////////////////////


//	t2 = CycleTimer::currentTicks();
//	cout << "Destroy: " << t2-t1 << "\n";
//	t1 = t2;
	return 0;
}


void SvmTrain::setup(std::vector<float>& raw_x, std::vector<int>& raw_y) {
	
    int deviceCount = 0;
    cudaError_t err = cudaGetDeviceCount(&deviceCount);

    printf("---------------------------------------------------------\n");
    printf("Initializing CUDA for CudaRenderer\n");
    printf("Found %d CUDA devices\n", deviceCount);

    for (int i=0; i<deviceCount; i++) {
        cudaDeviceProp deviceProps;
        cudaGetDeviceProperties(&deviceProps, i);
        printf("Device %d: %s\n", i, deviceProps.name);
        printf("   SMs:        %d\n", deviceProps.multiProcessorCount);
        printf("   Global mem: %.0f MB\n", static_cast<float>(deviceProps.totalGlobalMem) / (1024 * 1024));
        printf("   CUDA Cap:   %d.%d\n", deviceProps.major, deviceProps.minor);
    }
    printf("---------------------------------------------------------\n");
	
	x = thrust::host_vector<float>(raw_x);
	y = thrust::host_vector<int>(raw_y);

	//cout << "PRE COPY: 0\n";

	//Copy x and y to device
	g_x = thrust::device_vector<float>(x.begin(), x.end());
	g_y = thrust::device_vector<int>(y.begin(), y.end());
	
	g_x_hi = thrust::device_vector<float>(state.num_attributes);
	g_x_lo = thrust::device_vector<float>(state.num_attributes);
	
	// Initialize f on device
	g_f  = thrust::device_vector<float>(state.num_train_data);
	thrust::transform(g_y.begin(), g_y.end(), g_f.begin(), thrust::negate<float>());

	//Initialize alpha on device
	g_alpha = thrust::device_vector<float>(state.num_train_data, 0);
	
	g_x_sq = thrust::device_vector<float>(state.num_train_data);
	
	for( int i = 0; i < state.num_train_data; i++ )
	{
		g_x_sq[i] = thrust::inner_product(&g_x[i*state.num_attributes], &g_x[i*state.num_attributes] + state.num_attributes, &g_x[i*state.num_attributes], 0.0f);
	}

	init_cuda_handles();
	
	lineCache = new myCache(state.cache_size, state.num_train_data);

	raw_g_x = thrust::raw_pointer_cast(&g_x[0]);

}
//	t2 = CycleTimer::currentTicks();
	//cout << "POST INIT, PRE G_X_SQ CALC: " << t2 - t1 << "\n";
//	t1 = t2;


void SvmTrain::train_step() {

	thrust::device_vector<float>::iterator iter;
	//float* iter;

	//Set up I_set1 and I_set2
	thrust::device_vector<float> g_I_set1(state.num_train_data, 1000000000);
	thrust::device_vector<float> g_I_set2(state.num_train_data, -1000000000);
		
	thrust::for_each(thrust::make_zip_iterator(thrust::make_tuple(g_alpha.begin(), g_y.begin(), g_f.begin(), g_I_set1.begin(), g_I_set2.begin())),
 	                 thrust::make_zip_iterator(thrust::make_tuple(g_alpha.end(), g_y.end(), g_f.end(), g_I_set1.end(), g_I_set2.end())),
       	             arbitrary_functor(state.c));
	
	//get b_hi and b_low
	iter = thrust::max_element(g_I_set2.begin(), g_I_set2.end());//, compare_mine());

	int I_lo = iter - g_I_set2.begin();
	b_lo = *iter;

	//cout << "I_lo: \t" << I_lo << ", b_lo: \t" << b_lo << '\n';

	iter = thrust::min_element(g_I_set1.begin(), g_I_set1.end());

	int I_hi = iter - g_I_set1.begin();
	b_hi = *iter;

	//cout << "I_lo: \t" << I_lo << ", I_hi: \t" << I_hi << '\n';
	//cout << "b_lo: \t" << b_lo << ", b_hi: \t" << b_hi << '\n';

	int y_lo = y[I_lo];
	int y_hi = y[I_hi];
		
	float eta = rbf_kernel(I_hi,I_hi) + rbf_kernel(I_lo,I_lo) - (2*rbf_kernel(I_lo,I_hi)) ;
		
	//cout << "eta: " << eta << '\n';

	//obtain alpha_low and alpha_hi (old values)
	float alpha_lo_old = g_alpha[I_lo];
	float alpha_hi_old = g_alpha[I_hi];

	//update alpha_low and alpha_hi
	float s = y_lo*y_hi;
	float alpha_lo_new = alpha_lo_old + (y_lo*(b_hi - b_lo)/eta);
	float alpha_hi_new = alpha_hi_old + (s*(alpha_lo_old - alpha_lo_new));

	//clip new alpha values between 0 and C
	alpha_lo_new = clip_value(alpha_lo_new, 0.0, state.c);
	alpha_hi_new = clip_value(alpha_hi_new, 0.0, state.c);

	//cout << "alpha_lo_new: " << alpha_lo_new << '\n';
	//cout << "alpha_hi_new: " << alpha_hi_new << '\n';
	
	//store new alpha_1 and alpha_2 values
	g_alpha[I_lo] = alpha_lo_new;
	g_alpha[I_hi] = alpha_hi_new;

	//	t2 = CycleTimer::currentTicks();
	//	cout << "ALPHA UPDATE: " << t2-t1 << "\n";
	//	t1 = t2;
		//update f values
	update_f(I_lo, I_hi, y_lo, y_hi, alpha_lo_old, alpha_hi_old, alpha_lo_new, alpha_hi_new);

	//	t2 = CycleTimer::currentTicks();
	//	cout << "UPDATE_F: " << t2-t1 << "\n";
	//	t1 = t2;

	///Increment number of iterations to reach stopping condition
}

float SvmTrain::get_train_accuracy() {
	int num_correct = 0;

	thrust::host_vector<float> alpha = g_alpha; 
	float* raw_alpha = thrust::raw_pointer_cast(&alpha[0]);
	
	for(int i=0; i<state.num_train_data; i++) {
		//cout << "Iter: " << i << "\n";

		float dual = 0;

		for(int j=0; j<state.num_train_data; j++) {
			if(raw_alpha[j] != 0) {
				dual += y[j]*raw_alpha[j]*rbf_kernel(j,i);
			}
		}

		dual += b;

		int result = 1;
		if(dual < 0) {
			result = -1;
		}

		if(result == y[i]) {
			num_correct++;
		}
	}

	return ((float)num_correct/(state.num_train_data));
}

float SvmTrain::clip_value(float num, float low, float high) {
	if(num < low) {
		return low;
	} else if(num > high) {
		return high;
	}

	return num;
}


void SvmTrain::get_x(float* x, float* x_copy, int idx, int num_attributes) {
	int ctr = 0;

	int start_index = (idx*num_attributes);
	int end_index = start_index+num_attributes;

	for(int i = start_index; i < end_index; i++) {
		x_copy[ctr++] = x[i];
	}
}


float SvmTrain::rbf_kernel(int i1, int i2){
	
	float* i2_copy = new float[state.num_attributes];

	float* raw_i1 = thrust::raw_pointer_cast(&x[i1*state.num_attributes]);
	float* raw_i2 = thrust::raw_pointer_cast(&x[i2*state.num_attributes]);

	get_x(raw_i2, i2_copy, 0, state.num_attributes);
	
	cblas_saxpy(state.num_attributes, -1, raw_i1, 1, i2_copy, 1); 

	float norm_sq = cblas_sdot(state.num_attributes, i2_copy, 1, i2_copy, 1);

	float result = (float)exp(-1 *(float)state.gamma*norm_sq);

	delete [] i2_copy;

	return result;
}
