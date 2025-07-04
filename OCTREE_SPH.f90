module octree_module
  implicit none
  ! This module encapsulates all data types, parameters, and subroutines
  ! required for the SPH (Smoothed Particle Hydrodynamics) simulation
  ! coupled with a Barnes-Hut octree for gravitational interactions.

  ! Global Parameters:
  real, parameter :: G = 6.67430e-11        ! Gravitational constant (in SI units)
  real, parameter :: softening = 1.0e-5     ! Softening length to prevent singularities in gravitational force at very small distances
  integer, parameter :: dp = kind(1.0d0)    ! Defines double precision kind for real variables, ensuring high accuracy
  integer, parameter :: nq = 1000          ! Number of samples for the SPH kernel lookup tables.
                                           ! This determines the resolution of the pre-computed kernel values.
  real(dp), allocatable :: w_table(:), dw_table(:) ! Allocatable arrays to store pre-computed SPH kernel (W)
                                                   ! and its derivative (dW/dr) values.
  real(dp), parameter :: dq = 2.0_dp / nq   ! Step size for 'q' (normalized distance) in the kernel lookup tables.
                                           ! 'q' ranges from 0 to 2.
  real(dp), parameter :: smoothing = 10.0_dp 

  ! Represents a single SPH particle with its physical properties.
  type :: particle
    real(dp) :: mass                  ! Mass of the particle
    real(dp) :: density               ! Density of the particle (rho)
    real(dp) :: internal_energy       ! Internal energy per unit mass (u)
    real(dp) :: pressure              ! Pressure of the particle (P)
    real(dp) :: internal_energy_rate  ! Rate of change of internal energy (du/dt)
    real(dp), dimension(3) :: position ! 3D position vector (x, y, z)
    real(dp), dimension(3) :: velocity ! 3D velocity vector (vx, vy, vz)
    real(dp), dimension(3) :: acceleration ! 3D acceleration vector (ax, ay, az)
  end type particle

  ! Represents a node (branch) in the Barnes-Hut octree.
  type :: branch
    real(dp), dimension(3) :: center      ! Geometric center of the octree node's bounding box
    real(dp) :: size                     ! Side length of the cubic bounding box for this node
    integer :: n_particles              ! Number of particles contained directly within this node's 'particles' array.
    type(Particle), allocatable :: particles(:) ! Array of particles stored in this node.
    real(dp) :: mass_total               ! Total mass of all particles (or sub-nodes) within this node's bounds
    real(dp), dimension(3) :: mass_center ! Center of mass of all particles (or sub-nodes) within this node's bounds
    type(branch), allocatable :: children(:) ! Array of 8 child branches (sub-nodes) for hierarchical representation.

  end type branch

  contains

  ! Initializes the global lookup tables (w_table and dw_table) for the SPH kernel
  ! and its derivative. This pre-computation avoids repeated expensive calculations
  ! of the kernel function during the simulation.
  subroutine init_kernel_table()
    integer :: i       ! Loop index for table population
    real(dp) :: q      ! Normalized distance (r/h), ranging from 0 to 2

    ! Allocate memory for the kernel and derivative tables
    allocate(w_table(0:nq))
    allocate(dw_table(0:nq))

    do i = 0, nq
      q = i * dq ! Calculate current normalized distance
      if (q >= 0.0_dp .and. q <= 1.0_dp) then
        ! Kernel and derivative for the inner region (0 <= r/h <= 1)
        w_table(i) = 1.0_dp - 1.5_dp*q**2 + 0.75_dp*q**3
        dw_table(i) = -3.0_dp*q + 2.25_dp*q**2
      else if (q > 1.0_dp .and. q <= 2.0_dp) then
        ! Kernel and derivative for the outer region (1 < r/h <= 2)
        w_table(i) = 0.25_dp * (2.0_dp - q)**3
        dw_table(i) = -0.75_dp * (2.0_dp - q)**2
      else
        ! Outside the compact support (r/h > 2), kernel and derivative are zero
        w_table(i) = 0.0_dp
        dw_table(i) = 0.0_dp
      end if
    end do
  end subroutine init_kernel_table

  ! Retrieves interpolated SPH kernel values (W) and their derivatives (dW/dr)
  ! from the pre-computed tables for a given distance 'r' and smoothing length 'hi'.
  subroutine lookup_kernel(r, hi, Wi, dWi)
    real(dp), intent(in) :: r, hi ! Input: distance 'r' between particles, smoothing length 'hi'
    real(dp), intent(out) :: Wi, dWi ! Output: Interpolated kernel value W, and its derivative dW/dr
    integer :: i                 ! Index for table lookup
    real(dp) :: alpha, qi        ! Interpolation factor, normalized distance (r/hi)

    qi = r / hi ! Calculate normalized distance
    ! Check if the normalized distance is within the kernel's compact support [0, 2]
    if (qi >= 0.0_dp .and. qi <= 2.0_dp) then
      i = int(qi / dq) 
      alpha = (qi - i * dq) / dq 
      ! Perform linear interpolation to get the kernel and derivative values
      Wi = (1.0_dp - alpha) * w_table(i) + alpha * w_table(i+1)
      dWi = (1.0_dp - alpha) * dw_table(i) + alpha * dw_table(i+1)
    else
      ! If outside the compact support, kernel values are zero
      Wi = 0.0_dp
      dWi = 0.0_dp
    end if
  end subroutine lookup_kernel

  ! Recursive Subroutine: build_tree
  ! Constructs the Barnes-Hut octree by recursively subdividing nodes.
  ! It distributes particles into 8 child octants if a node contains too many particles
  ! or has not reached the maximum recursion depth.
  recursive subroutine build_tree(node, depth, max_particles)
    implicit none
    type(branch), intent(inout) :: node      ! The current octree node being processed.
                                            ! 'inout' because its children array and particle lists are modified.
    integer, intent(in) :: depth, max_particles ! Input: current recursion depth, max particles allowed in a leaf node.

    integer :: i, j, n                        ! Loop indices and temporary size variable
    real(dp), dimension(3) :: offset         ! Spatial offset for calculating child node centers
    type(Particle), allocatable :: child_particles(:) ! Temporary array used for reallocating child particle arrays
    integer :: child_index                    ! Index (1-8) representing which child octant a particle belongs to
    integer :: p                              ! Particle loop index

    ! Compute total mass and center of mass for the current node.
    ! This is done first, before subdivision, so that this node's properties
    ! can be used for gravitational force calculations later.
    node%mass_total = 0.0_dp
    node%mass_center = 0.0_dp
    do i = 1, size(node%particles)
      node%mass_total = node%mass_total + node%particles(i)%mass
      node%mass_center = node%mass_center + node%particles(i)%mass * node%particles(i)%position
    end do
    if (node%mass_total > 0.0_dp) then
      node%mass_center = node%mass_center / node%mass_total
    else
      ! If the node has no mass (e.g., no particles or all particles have zero mass),
      ! its center of mass is set to its geometric center.
      node%mass_center = node%center
    end if

    ! Base case for recursion:
    ! If the number of particles in the node is less than or equal to `max_particles` (making it a leaf node),
    ! OR if the maximum recursion `depth` has been reached, stop subdividing.
    if (size(node%particles) <= max_particles .or. depth == 0) return

    ! If not a base case, allocate 8 child nodes for this branch.
    allocate(node%children(8))
    do i = 1, 8
      node%children(i)%size = node%size / 2.0_dp ! Each child's size is half of the parent's
      node%children(i)%n_particles = 0           ! Initialize particle count for child to zero
      allocate(node%children(i)%particles(0))    ! Allocate an empty array for particles in the child node
      node%children(i)%center = node%center      ! Start with parent's center for calculating child's center

      do j = 1, 3
        if (btest(i - 1, j - 1)) then ! If j-th bit is set (for x, y, or z)
          offset(j) = 0.25_dp * node%size ! Positive offset for this dimension
        else
          offset(j) = -0.25_dp * node%size ! Negative offset for this dimension
        end if
      end do
      node%children(i)%center = node%center + offset ! Set the child's actual center
    end do

    ! Distribute particles from the current node to its newly created children.
    do p = 1, size(node%particles)
      child_index = 1 ! Initialize child index (corresponds to octant 1)
      ! Determine which child octant the current particle `node%particles(p)` belongs to.
      do j = 1, 3
        if (node%particles(p)%position(j) > node%center(j)) then
          child_index = ibset(child_index - 1, j - 1) + 1
        end if
      end do

      ! Add the particle to the selected child node's particle list.
      n = size(node%children(child_index)%particles) ! Current number of particles in the target child
      ! `move_alloc` is used for efficient reallocation of arrays, preventing full data copy.
      call move_alloc(node%children(child_index)%particles, child_particles)
      allocate(node%children(child_index)%particles(n + 1)) ! Allocate space for one more particle
      if (n > 0) node%children(child_index)%particles(1:n) = child_particles ! Copy existing particles back
      node%children(child_index)%particles(n + 1) = node%particles(p) ! Add the new particle (member-wise copy)
      node%children(child_index)%n_particles = node%children(child_index)%n_particles + 1 ! Increment child's particle count
    end do

    ! Recursively call build_tree for each child node that contains particles.
    do i = 1, 8
      if (node%children(i)%n_particles > 0) then
        call build_tree(node%children(i), depth - 1, max_particles)
      end if
    end do
  end subroutine build_tree

  ! Recursive Subroutine: navigate_tree
  ! Traverses the octree to calculate the gravitational acceleration on a given 'body' particle
  ! using the Barnes-Hut approximation.
  recursive subroutine navigate_tree(node, body, theta)
  implicit none
  type(branch), intent(in) :: node             ! The current octree node being evaluated.
  type(particle), intent(inout) :: body(:)    ! Array containing the single particle for which forces are calculated.
                                             ! Using array slice `body(i:i)` for consistency in recursive calls.
  real(dp), intent(in) :: theta                ! Barnes-Hut opening angle criterion (typically 0.5 to 1.0).
                                             ! If `node%size / dist < theta`, the node is treated as a single mass.

  real(dp) :: dist, d2                       ! Distance between particle and node's center of mass, and its square
  real(dp), dimension(3) :: direction         ! Vector from particle to node's center of mass
  integer :: i, k                             ! Loop indices

  ! Loop over the (single) particle provided in the 'body' array slice.
  do i = 1, size(body)
    direction = body(i)%position - node%mass_center ! Vector pointing from particle to the node's center of mass
    d2 = sum(direction**2) + softening**2           ! Squared distance, with softening to avoid division by zero
    dist = sqrt(d2)                               ! Euclidean distance

    ! Barnes-Hut criterion:
    ! If the node is sufficiently far away (ratio of size to distance is small),
    ! OR if the node is a leaf node (no children allocated), treat it as a single point mass.
    if ((node%size / dist) < theta .or. .not. allocated(node%children)) then
      ! Calculate gravitational acceleration if the node has mass and distance is positive.
      if (node%mass_total > 0.0_dp .and. dist > 0.0_dp) then
        body(i)%acceleration = body(i)%acceleration - (G * node%mass_total * direction / (dist**3))
      end if
    else if (allocated(node%children)) then
      ! If the criterion is not met and the node has children, recurse into each child node.
      do k = 1, size(node%children)
        if (node%children(k)%n_particles > 0) then
          call navigate_tree(node%children(k), body(i:i), theta) ! Recurse, passing the same particle
        end if
      end do
    end if
  end do
  end subroutine navigate_tree

  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!PAST THIS POINT THE STUFF WORKS FINE!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

  ! Subroutine: get_SPH
  ! Orchestrates the calculation of SPH forces and internal energy rates for all particles.
  subroutine get_SPH(root, body)
    implicit none
    type(branch), intent(in) :: root           ! The root node of the octree.
    type(particle), intent(inout) :: body(:)  ! Array of all particles in the simulation.

    integer :: i                               ! Loop index

    ! Loop through each particle in the main `body` array.
    do i = 1, size(body)
      ! For each particle, search the octree to find its SPH neighbors and
      ! accumulate SPH terms (pressure forces, internal energy rates).
      call SPH_tree_search(root, body(i))
    end do
  end subroutine get_SPH

  ! Searches the octree for neighbors of a given 'body' particle within its smoothing length,
  ! and calculates the SPH interaction terms (pressure force and internal energy rate).
  recursive subroutine SPH_tree_search(node, body)
    implicit none
    type(branch), intent(in) :: node          ! Current octree node being examined.
    type(particle), intent(inout) :: body     ! The single particle for which SPH interactions are calculated.
    real(dp), dimension(3) :: over_dr, nr, dWj, vij ! over_dr: vector from body to node center; nr: normalized separation vector;
                                                 ! dWj: gradient of kernel; vij: relative velocity vector.
    real(dp) :: Wj, dr, mj, dWj_mag, vdotW   ! Wj: kernel value; dr: distance; mj: neighbor mass;
                                             ! dWj_mag: magnitude of kernel derivative; vdotW: (v_ij . grad(W_ij)).
    integer :: j                             ! Loop index for children
    logical :: has_children                   ! Flag indicating if the current node has children.

    has_children = allocated(node%children)
    ! Calculate vector from the 'body' particle's position to the current node's center.
    over_dr = (body%position - node%center)

    ! Recursion condition:
    ! If the node contains multiple particles AND the 'body' particle's smoothing sphere
    ! potentially overlaps this node's bounding box (indicated by `abs(over_dr) < (2*smoothing + node%size/2)`),
    ! AND the node has children, then recurse into its children.
    if (node%n_particles > 1 .and. all(abs(over_dr) < (2.0_dp*smoothing + node%size/2.0_dp)) .and. has_children) then
      do j = 1, size(node%children)
        ! Only recurse if the child node actually contains particles.
        if (node%children(j)%n_particles > 0) then
          call SPH_tree_search(node%children(j), body)
        end if
      end do

    ! Base case:
    ! If the node is a leaf node (contains exactly one particle) AND the 'body' particle's smoothing sphere
    ! potentially overlaps this node's bounding box, then this single particle in the leaf node
    ! is a candidate neighbor for 'body'.
    else if (node%n_particles == 1 .and. all(abs(over_dr) < (2.0_dp*smoothing + node%size/2.0_dp))) then
      ! This is where the interaction with a single neighbor particle (node%particles(1)) occurs.
      nr = (body%position - node%particles(1)%position) ! Vector from neighbor to the 'body' particle
      dr = sqrt(sum(nr**2))                             ! Distance between the 'body' and its neighbor

      if (dr == 0.0_dp) return

      vij = (body%velocity - node%particles(1)%velocity) ! Relative velocity between 'body' and neighbor
      nr = nr / dr ! Normalize the separation vector

      ! Lookup kernel (W) and derivative (dW/dr) values for the calculated distance 'dr'.
      call lookup_kernel(dr, smoothing, Wj, dWj_mag)
      ! Normalize kernel and its gradient for 3D cubic spline:
      Wj = Wj / (3.14159265359_dp * smoothing**3)
      dWj = nr * dWj_mag / (3.14159265359_dp * smoothing**4)
      mj = node%particles(1)%mass ! Mass of the neighbor particle

      ! Accumulate SPH pressure force:
      ! F_i = - sum_j m_j (P_i/rho_i^2 + P_j/rho_j^2) grad(W_ij)
      ! The acceleration is a_i = F_i / m_i (implicitly included by `body%acceleration = body%acceleration - ...`)
      body%acceleration = body%acceleration - mj * ((body%pressure/(body%density * body%density)) + &
                                                  (node%particles(1)%pressure / (node%particles(1)%density * node%particles(1)%density))) * dWj

      vdotW = sum(vij * dWj)
      ! Accumulate rate of change in internal energy:
      body%internal_energy_rate = body%internal_energy_rate + (body%pressure/body%density)*mj*(vdotW)
      return 
    end if
    ! If neither recursion nor leaf node interaction conditions are met, simply return.
  end subroutine SPH_tree_search

  ! Subroutine: get_density
  ! Calculates the density for all particles in the `body` array by summing contributions
  ! from their neighbors using the tree structure.
  subroutine get_density(root, body)
    implicit none
    type(branch), intent(inout) :: root           ! The root node of the octree.
                                                ! 'inout' is used for `node%particles(1)%density` update.
    type(particle), intent(inout) :: body(:)    ! Array of all particles.

    integer :: i                                  ! Loop index
    logical :: has_children                       ! Local flag for node having children

    has_children = allocated(root%children)
    ! Loop through each particle to calculate its density.
    do i = 1, size(body)
      body(i)%density = 0.0_dp ! Initialize density to zero before accumulating contributions for particle `i`.
      ! Search the tree to find all neighbors and accumulate density contributions for `body(i)`.
      call density_tree_search(root, body(i))
    end do

    !now distribute the density to the tree
    call sync_density_to_tree(root, body)

  end subroutine get_density

  ! Recursively traverses the octree to find neighbors for a given 'body' particle
  ! and accumulates its density based on SPH formalism.
  recursive subroutine density_tree_search(node, body)
    implicit none
    type(branch), intent(inout) :: node          ! Current node in the tree. 'inout' allows modification
                                                ! of `node%particles(1)%density` if this node is a leaf.
    type(particle), intent(inout) :: body     ! The specific particle whose density is being calculated.
    real(dp), dimension(3) :: over_dr, nr     ! over_dr: vector from body to node center; nr: normalized separation vector.
    real(dp) :: Wj, dr, mj, dWj_mag          ! Wj: kernel value; dr: distance; mj: neighbor mass;
                                             ! dWj_mag: magnitude of kernel derivative.
    integer :: j                             ! Loop index for children
    logical :: has_children                   ! Flag indicating if the current node has children.

    has_children = allocated(node%children)
    ! Calculate vector from the 'body' particle's position to the current node's center.
    over_dr = (body%position - node%center)

    ! Recursion condition:
    ! potentially overlaps this node's bounding box, AND the node has children, then recurse.
    if (node%n_particles > 1 .and. all(abs(over_dr) < (2.0_dp*smoothing + node%size/2.0_dp)) .and. has_children) then
      do j = 1, size(node%children)
        ! Only recurse if the child node actually contains particles.
        if (node%children(j)%n_particles > 0) then
          call density_tree_search(node%children(j), body)
        end if
      end do

    ! Base case:
    ! If the node is a leaf node (contains exactly one particle) AND the 'body' particle's smoothing sphere
    ! potentially overlaps this node's bounding box, then this single particle in the leaf node
    ! is a candidate neighbor for 'body'.
    else if (node%n_particles == 1 .and. all(abs(over_dr) < (2.0_dp*smoothing + node%size/2.0_dp))) then
      ! Get the neighbor particle from the leaf node (node%particles(1)).
      nr = (body%position - node%particles(1)%position) ! Vector from neighbor to the 'body' particle
      dr = sqrt(sum(nr**2))                             ! Distance between them
      !if (dr == 0.0_dp) return

      ! Lookup kernel (W) value for the calculated distance 'dr'.
      call lookup_kernel(dr, smoothing, Wj, dWj_mag) ! dWj_mag is not used for density, but still returned.
      ! Normalize kernel for 3D cubic spline.
      Wj = Wj / (3.14159265359_dp * smoothing**3)
      mj = node%particles(1)%mass ! Mass of the neighbor particle

      ! Accumulate density for the 'body' particle: rho_i = sum_j m_j * W_ij
      body%density = body%density + mj * Wj
      return
    end if
  end subroutine density_tree_search

  recursive subroutine sync_density_to_tree(node, bodies)
    implicit none
    type(branch), intent(inout) :: node
    type(particle), intent(in)  :: bodies(:)
    integer :: i

    ! For each particle in this node, find the corresponding particle in bodies by position and set density
    do i = 1, size(node%particles)
      ! Simple approach: assume the i-th particle in node%particles corresponds to i-th in bodies
      ! (if you always copy bodies into root%particles in order)
      node%particles(i)%density = bodies(i)%density
      node%particles(i)%pressure = (0.66666666666666667_dp) * bodies(i)%internal_energy * bodies(i)%density

      if (node%particles(i)%density == 0.0_dp) stop
    end do

    ! Recurse into children if present
    if (allocated(node%children)) then
      do i = 1, size(node%children)
        if (node%children(i)%n_particles > 0) then
          call sync_density_to_tree(node%children(i), bodies)
        end if
      end do
    end if
  end subroutine sync_density_to_tree
  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

  ! Subroutine: simulate
  ! The main simulation loop, which advances the state of all particles over time.
  ! It employs a two-step integration scheme (similar to velocity Verlet) and
  ! recalculates forces and properties at each step.
  subroutine simulate(bodies)
    implicit none
    type(particle), intent(inout) :: bodies(:) ! Array of all particles in the simulation.
    type(branch), allocatable :: root           ! The root node of the octree. Allocated and deallocated within the loop.
    real(dp) :: t, dt, end_time                ! Current simulation time, time step size, and simulation end time.
    integer :: i,io                            ! Loop index.

    t = 0.0_dp         ! Initialize simulation time.
    end_time = 1000.0_dp ! Set simulation end time.
    dt = 0.8_dp          ! Set time step size.

    ! Main simulation loop: continue as long as current time is less than end time.
    do while (t < end_time)
      ! === First Half-Step of Integration ===

      ! 1. Allocate and initialize the root node for tree building.
      allocate(root)
      ! Initialize root node's bounding box based on the min/max positions of all particles.
      ! This ensures the tree spans the entire particle distribution.
      root%center = [(maxval(bodies%position(1)) + minval(bodies%position(1)))/2.0_dp, &
                     (maxval(bodies%position(2)) + minval(bodies%position(2)))/2.0_dp, &
                     (maxval(bodies%position(3)) + minval(bodies%position(3)))/2.0_dp]
      root%size = maxval([(maxval(bodies%position(1)) - minval(bodies%position(1))), &
                          (maxval(bodies%position(2)) - minval(bodies%position(2))), &
                          (maxval(bodies%position(3)) - minval(bodies%position(3)))])

      root%n_particles = size(bodies) ! Set the number of particles in the root node.
      allocate(root%particles(size(bodies))) ! Allocate space for copies of all particles in the root.
      root%particles = bodies ! Copy current particle states into the root node for tree construction.

      ! 2. Build the octree from the current particle positions.
      call build_tree(root, 1000, 1) ! `depth` limit 1000, `max_particles` per leaf node 1.

      ! 3. Calculate densities for all particles using the newly built tree.
      call get_density(root, bodies)

      ! 4. Calculate pressures for all particles using an Equation of State (EOS).
      ! Assuming P = (gamma - 1) * rho * u, with (gamma - 1) = 2/3.
      do i = 1, root%n_particles
        bodies(i)%pressure = (0.66666666666666667_dp) * bodies(i)%internal_energy * bodies(i)%density
      end do

      ! 6. Calculate gravitational acceleration for all particles using Barnes-Hut.
      ! Initial acceleration is reset before accumulation.
      do i = 1, root%n_particles
        bodies(i)%acceleration = [0.0_dp, 0.0_dp, 0.0_dp]
      end do
      call navigate_tree(root, bodies, 0.5_dp) ! `theta` criterion 0.5.

      ! 7. Calculate SPH accelerations (pressure forces) and internal energy rates.
      ! Initial internal energy rate is reset within `get_SPH` before accumulation.
      call get_SPH(root, bodies)

      ! 8. Update velocities (first half-kick) and internal energies (half-step).
      do i = 1, root%n_particles
        bodies(i)%velocity = bodies(i)%velocity + (bodies(i)%acceleration)*dt/2.0_dp
        bodies(i)%internal_energy = bodies(i)%internal_energy + (bodies(i)%internal_energy_rate)*dt/2.0_dp
      end do

      ! 9. Update positions (first half-drift), and reset accelerations/internal_energy_rates for next force calculation.
      do i = 1, root%n_particles
        bodies(i)%position = bodies(i)%position + (bodies(i)%velocity)*dt/2.0_dp
        bodies(i)%acceleration = [0.0_dp, 0.0_dp, 0.0_dp]
        bodies(i)%internal_energy_rate = 0.0_dp
      end do

      deallocate(root) ! Deallocate the current tree before rebuilding for the second half.

      ! === Second Half-Step of Integration ===
      ! Recalculate forces based on the new (half-drifted) positions for the second kick.

      ! 10. Re-allocate and re-initialize the root node with the updated positions.
      allocate(root)
      root%center = [(maxval(bodies%position(1)) + minval(bodies%position(1)))/2.0_dp, &
                     (maxval(bodies%position(2)) + minval(bodies%position(2)))/2.0_dp, &
                     (maxval(bodies%position(3)) + minval(bodies%position(3)))/2.0_dp]
      root%size = maxval([(maxval(bodies%position(1)) - minval(bodies%position(1))), &
                          (maxval(bodies%position(2)) - minval(bodies%position(2))), &
                          (maxval(bodies%position(3)) - minval(bodies%position(3)))])

      root%n_particles = size(bodies)
      allocate(root%particles(size(bodies)))
      root%particles = bodies

      ! 11. Rebuild the octree.
      call build_tree(root, 1000, 1)

      ! 12. Recalculate densities.
      call get_density(root, bodies)

      ! 13. Recalculate pressures.
      do i = 1, root%n_particles
        bodies(i)%pressure = (0.66666666666666667_dp) * bodies(i)%internal_energy * bodies(i)%density
        if (bodies(i)%pressure < 0.0_dp) bodies(i)%pressure = 0.0_dp
      end do

      ! 15. Recalculate gravitational acceleration.
      call navigate_tree(root, bodies, 0.5_dp)

      ! 16. Recalculate SPH accelerations and internal energy rates.
      call get_SPH(root, bodies)

      ! 17. Final update of velocities (second half-kick) and internal energies (second half-step).
      ! The positions are also updated here with the second half-drift to complete the full step.
      do i = 1, root%n_particles
        bodies(i)%velocity = bodies(i)%velocity + (bodies(i)%acceleration)*dt/2.0_dp
        bodies(i)%internal_energy = bodies(i)%internal_energy + (bodies(i)%internal_energy_rate)*dt/2.0_dp
        bodies(i)%position = bodies(i)%position + (bodies(i)%velocity)*dt/2.0_dp ! This completes the full position update (first half was above).
      end do

      deallocate(root) 
      t = t + dt 
    end do

    open(newunit=io, file="log.txt", status="new", action = "write")
    do i = 1, size(bodies)
      write(io, *)  "Position:", bodies(i)%position(1),bodies(i)%position(2),bodies(i)%position(3), "Density:", bodies(i)%density
    end do  
    close(io)
  end subroutine simulate
end module octree_module

program barnes_hut
  use octree_module  
  implicit none      

  integer :: n, total_particles   ! Loop counter and total number of particles
  type(particle), allocatable :: bodies(:) ! Allocatable array to hold all particles in the simulation

  ! Initialize the SPH kernel lookup tables (W and dW/dr). This needs to be done once at the start.
  call init_kernel_table()

  ! Define the total number of particles for the simulation.
  total_particles = 500
  ! Allocate memory for the array of particles.
  allocate(bodies(total_particles))

  ! Initialize the properties of each particle.
  do n = 1, total_particles
    call random_number(bodies(n)%position) ! Generate random numbers (0 to 1) for initial positions.
    ! Scale and shift positions to be within a cube (e.g., from 0 to 12).
    bodies(n)%position = 12.0_dp * bodies(n)%position

    bodies(n)%mass = 100.0_dp           ! Assign a mass to each particle.
    call random_number(bodies(n)%velocity) ! Generate random numbers for initial velocities.
    ! Scale velocities to be very small, effectively starting from rest or very slow movement.
    bodies(n)%velocity = 0.000_dp * bodies(n)%velocity

    bodies(n)%pressure = 1.0_dp       ! Initial placeholder pressure. This will be updated by the EOS.
    bodies(n)%internal_energy = 1.0_dp ! Initial internal energy.
    bodies(n)%density = 0.0_dp         ! Initial density set to zero. This will be calculated in `get_density`.
  end do

  ! Start the main simulation loop.
  call simulate(bodies)

end program barnes_hut
