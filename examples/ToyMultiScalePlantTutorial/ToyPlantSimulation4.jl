###########################################
# Toy plant model MTG visualisation using PlantGeom
###########################################
using PlantSimEngine

using MultiScaleTreeGraph
using PlantSimEngine.Examples
using Pkg
Pkg.add("CSV")
using CSV
include("ToyPlantSimulation3.jl")

using Plots
using PlantGeom
# reusing the mtg from part 3:
RecipesBase.plot(mtg)

#=
using GLMakie
#using CairoMakie
using PlantGeom

PlantGeom.diagram(mtg)=#


using PlantGeom.Meshes

# Internodes and roots will use a cylinder as a mesh

cylinder() = Meshes.CylinderSurface(1.0) |> Meshes.discretize |> Meshes.simplexify

refmesh_internode = PlantGeom.RefMesh("Internode", cylinder())
refmesh_root = PlantGeom.RefMesh("Root", cylinder())

# Leaves and petioles are a single mesh, read from a .ply file 

Pkg.add("PlyIO")
using PlyIO
function read_ply(fname)
    ply = PlyIO.load_ply(fname)
    x = ply["vertex"]["x"]
    y = ply["vertex"]["y"]
    z = ply["vertex"]["z"]  
    points = Meshes.Point.(x, y, z)
    connec = [Meshes.connect(Tuple(c .+ 1)) for c in ply["face"]["vertex_indices"]]
    Meshes.SimpleMesh(points, connec)
end

leaf_ply = read_ply("examples/leaf_with_petiole.ply")
refmesh_leaf = PlantGeom.RefMesh("Leaf", leaf_ply)

Pkg.add("TransformsBase")
Pkg.add("Rotations")
#using PlantGeom.TranformsBase
import TransformsBase: →
import Rotations: RotY, RotZ, RotX
# Add the geometry to the MTG, with transformations
function add_geometry!(mtg, refmesh_internode) 
    
    # incremental offset
    internode_height = 0.0

    # relative scale of the base mesh
    internode_width = 0.5

    # length of the base mesh
    internode_length = 1.0

    traverse!(mtg) do node
        if symbol(node) == "Internode"
            # Set to scale, then translate by the total height
            mesh_transformation = Meshes.Scale(internode_width, internode_width, internode_length) → Meshes.Translate(0.0, 0.0, internode_height)
            node.geometry = PlantGeom.Geometry(ref_mesh=refmesh_internode, transformation=mesh_transformation)
            
            internode_height += internode_length
        end
    end
end

add_geometry!(mtg, refmesh_internode)

# Visualize the mesh
using GLMakie
viz(mtg)    

function add_geometry!(mtg, refmesh_internode, refmesh_root, refmesh_leaf) 
    
    # incremental offset
    internode_height = 0.0
    root_depth = 0.0

    # relative scale of the base mesh
    internode_width = 0.5
    root_width = 0.2

    # length of the base mesh
    internode_length = 1.0
    root_length = 1.0

    # ad hoc value to adjust the base mesh to the scene scale
    leaf_mesh_scale = 25
    leaf_scale_width = 0.4*leaf_mesh_scale
    leaf_scale_height = 0.4*leaf_mesh_scale
    
    # Helpers to make the leaves opposite decussate
    leaf_rotation = MathConstants.pi / 2.0
    i = 0

    traverse!(mtg) do node
        if symbol(node) == "Internode"
            # Set to scale, then translate by the total height
            mesh_transformation = Meshes.Scale(internode_width, internode_width, internode_length) → Meshes.Translate(0.0, 0.0, internode_height)
            node.geometry = PlantGeom.Geometry(ref_mesh=refmesh_internode, transformation=mesh_transformation)
            
            internode_height += node_length

            # Leaves are placed relatively to the parent internode
            for chnode in children(node)               
                if symbol(chnode) == "Leaf" 
                    # Leaves are placed halfway along the the parent internode
                    mesh_transformation = Meshes.Scale(leaf_scale_width, leaf_scale_width, leaf_scale_height) → Meshes.Rotate(RotX(-MathConstants.pi / 6.0)) → Meshes.Translate(0.0, -internode_width, internode_height - internode_length / 2.0) → Meshes.Rotate(RotZ(leaf_rotation))
                    chnode.geometry = PlantGeom.Geometry(ref_mesh=refmesh_leaf, transformation=mesh_transformation)
                    # Set the second leaf in a pair opposite to the first one => add a 180° rotation
                    leaf_rotation += MathConstants.pi
                end                
            end

            # Opposite decussate => 90° rotation between pairs
            i += 1
            if i % 2 == 0
                leaf_rotation = MathConstants.pi / 2.0
            else
                leaf_rotation = MathConstants.pi
            end

        elseif symbol(node) == "Root"
            mesh_transformation = Meshes.Scale(root_width, root_width, root_length) → Meshes.Translate(0.0, 0.0, root_depth) → Meshes.Rotate(RotZ(MathConstants.pi))
            node.geometry = PlantGeom.Geometry(ref_mesh=refmesh_root, transformation=mesh_transformation)
            root_depth -= root_length
        end
    end
end

add_geometry!(mtg, refmesh_internode, refmesh_root, refmesh_leaf)

# Visualize the mesh
using GLMakie
viz(mtg)    