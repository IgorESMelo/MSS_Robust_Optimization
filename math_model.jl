using Gurobi
using JuMP

# Exporting the main functions
include("read_instance.jl")
using .ReadInstance

# Set the parameters for the model and run it
function run_all_configs_math_model()
    delta = [11, 33, 55]    # The upper bound of changes in the MSS solution (i.e., the number of rooms that can be changed in the MSS solution)
    gamma1 = [0, 1, 2]      # The upper bound of uncertainty in the OR time (i.e., the number of surgeries that can have their OR time increased)
    gamma2 = [0, 4, 8]      # The upper bound of uncertainty in the PO time (i.e., the number of surgeries that can have their PO time increased)
    gamma3 = [0, 2, 4]      # The upper bound of uncertainty in the ICU time (i.e., the number of surgeries that can have their ICU time increased)
    filename = ["Instances/instance_030_33_33_33.txt", "Instances/instance_030_20_20_60.txt", "Instances/instance_030_20_60_20.txt", "Instances/instance_030_60_20_20.txt",
                "Instances/instance_040_33_33_33.txt", "Instances/instance_040_20_20_60.txt", "Instances/instance_040_20_60_20.txt", "Instances/instance_040_60_20_20.txt",
                "Instances/instance_050_33_33_33.txt", "Instances/instance_050_20_20_60.txt", "Instances/instance_050_20_60_20.txt", "Instances/instance_050_60_20_20.txt"]

    # Loop to automatically run the model for all instances and configurations
    for st in filename, d in delta, i in gamma1, j in gamma2, k in gamma3
        run(st, "MSS_ref.txt", i, j, k, d)
    end
end

# Function to run the mathematical model
function run(filename::String, filename2::String, Γ1::Int64, Γ2::Int64, Γ3::Int64, delta::Int64)
    #=  filename::String: The path to the instance file containing the problem data.
        filename2::String: The path to the file containing the MSS solution.    
        Γ1::Int64: The upper bound of uncertainty in the OR time
        Γ2::Int64: The upper bound of uncertainty in the PO time
        Γ3::Int64: The upper bound of uncertainty in the ICU time
        delta::Int64: The value of the uncertainty parameter   =#
    
    # Reading the instance data and MSS solution
    desvio_OR, desvio_PO, desvio_ICU, nb_specialties, nb_patients, nb_rooms, nb_days, nb_shifts, capacidade_OR, capacidade_PO, capacidade_ICU, patient_by_specialty, MSS, pac_esperados, 
    cplx_esperada, air, bid, cplx_paciente, tempo_espera, tempo_OR, tempo_PO, precisa_ICU, tempo_ICU = ReadInstance.read_instance(filename, filename2)
    
    # Creating the mathematical model based on the input parameters and the chosen configuration (robust or deterministic)
    # To create the robust model, we need to pass the uncertainty parameters (Γ1, Γ2, Γ3) to the function creating_robust. For the deterministic model, we can set these parameters to zero.
    model = nothing
    init_time = 0
    model, init_time = creating_robust(desvio_OR, desvio_PO, desvio_ICU, Γ1, Γ2, Γ3, nb_specialties, nb_patients, nb_rooms, nb_days, nb_shifts, capacidade_OR, capacidade_PO, 
                        capacidade_ICU, patient_by_specialty, MSS, pac_esperados, cplx_esperada, air, bid, cplx_paciente, tempo_espera, tempo_OR, tempo_PO, precisa_ICU, tempo_ICU, filename, delta)
    
    # Optimizing the model and printing the results
    println("Optimizing the model...")
    optimize!(model)
    println("Status: ", termination_status(model))
    tempo_execucao = round((time_ns() - init_time) * 1e-9; digits=4)
    println("Elapsed time in seconds = $tempo_execucao \n")
    obj_value = JuMP.objective_value(model)
    println("Valor Ótimo da Função Objetivo: ", obj_value)
    
    # Externing the results to a text file
    st = filename[11:length(filename)-4]
    open("delta_$(delta)_math-model_$(st)_G1_$(Γ1)_G2_$(Γ2)_G3_$(Γ3).txt", "a") do file
        # Printing the head of the results file
        println(file, "Status: ", termination_status(model))
        println(file, "Elapsed time in seconds = $tempo_execucao")
        println(file, "Valor Ótimo da Função Objetivo: $obj_value \n\n")

        # Printing the assignments per room and shift
        println(file, "Assignments per room and shift:")
        espera_total = 0
        nb_works_shifts = 2
        is_workday(d) = mod1(d, 7) <= 5
        Uw = [ (d-1)*nb_shifts + s for d in 1:nb_days for s in 1:nb_works_shifts if is_workday(d) ]
        for r in 1:nb_rooms, u in Uw
            for i in 1:nb_specialties
                if JuMP.value(model[:y][i, r, u]) > 0.5
                    println(file, "-- Room ", r, " at Time Slot ", u, " assigned to Specialty ", i)
                    print(file, "Surgeries allocated: ")
                    for j in 1:nb_patients
                        if JuMP.value(model[:x][j, r, u]) > 0.5
                            print(file, "$j($(tempo_espera[j] + u)) - ")
                        end
                    end
                    print(file, "\n")
                end
            end
        end

        # Printing the changes in the MSS solution
        println(file, "Changes in previous MSS:")
        for r in 1:nb_rooms, u in Uw
            for i in 1:nb_specialties
                if JuMP.value(model[:y][i, r, u]) > 0.5 && MSS[i, r, u] == 0
                    println(file, "-- Room ", r, " at Time Slot ", u, " added to Specialty ", i, " -- Room ocupaction: $(sum(JuMP.value(model[:y][i, r, u]) for i in 1:nb_specialties))")
                elseif JuMP.value(model[:y][i, r, u]) < 0.5 && MSS[i, r, u] == 1
                    println(file, "-- Room ", r, " at Time Slot ", u, " removed Specialty ", i, "-- Room ocupaction: $(sum(JuMP.value(model[:y][i, r, u]) for i in 1:nb_specialties))")
                end
            end
        end

        # Printing the downstream patient assignments and the usage of PO and ICU per time slot
        println(file, "Downstream patient assignments:")
        use_PO = zeros(Int64, nb_days*nb_shifts)
        use_ICU = zeros(Int64, nb_days*nb_shifts)
        for u in 1:(nb_days*nb_shifts) # Ou seja, set U
            if u in Uw
                for j in 1:nb_patients
                    if JuMP.value(model[:v][j, u]) > 0.5
                        if precisa_ICU[j] == 0
                            for u_po in u:(u + tempo_PO[j] - 1)
                                if u_po <= (nb_days*nb_shifts)
                                    use_PO[u_po] += 1
                                end
                            end
                        else
                            for u_icu in u:(u + tempo_PO[j] + tempo_ICU[j] - 1)
                                if u_icu <= u + tempo_ICU[j] - 1 && u_icu <= (nb_days*nb_shifts)
                                    use_ICU[u_icu] += 1
                                elseif u_icu <= (nb_days*nb_shifts)
                                    use_PO[u_icu] += 1
                                end
                            end
                        end
                    end
                end
            end
        end

        # Printing the usage of PO beds per time slot
        println(file, "Post-Operative Usage per Time Slot:")
        for u in 1:(nb_days*nb_shifts)
            println(file, "Time Slot ", u, ": ", use_PO[u], " patients")
        end

        # Printing the usage of ICU beds per time slot
        println(file, "\nICU Usage per Time Slot:")
        for u in 1:(nb_days*nb_shifts)
            println(file, "Time Slot ", u, ": ", use_ICU[u], " patients")
        end

        # Printing the patient assignments and their waiting times
        println(file, "\nPatient Assignments and Waiting Times:")
        for j in 1:nb_patients
            assignment = false
            for r in 1:nb_rooms, u in Uw
                if JuMP.value(model[:x][j, r, u]) > 0.5
                    println(file, "Patient ", j, " assigned to Room ", r, " at Time Slot ", u, " -- Tempo de espera: ", tempo_espera[j] + u)
                    espera_total += tempo_espera[j] + u
                    assignment = true
                    break
                end
            end
            if assignment == false
                println(file, "Patient ", j, " not assigned. Tempo de espera: ", (nb_days * nb_shifts) + 1 + tempo_espera[j])
                espera_total += (nb_days * nb_shifts) + 1 + tempo_espera[j]
            end
        end

        # Printing the total waiting time, average waiting time, complexity of the selected mix, number of allocated patients, and the slack of complexity and volume
        println(file, "Total Espera: ", espera_total)
        println(file, "Tempo Médio de Espera: ", espera_total / nb_patients)
        println(file, "Complexidade do mix selecionado: ", sum(cplx_paciente[j] * sum(JuMP.value(model[:x][j, r, u]) for r in 1:nb_rooms, u in Uw) for j in 1:nb_patients))
        println(file, "Número de pacientes alocados: ", sum(sum(JuMP.value(model[:x][j, r, u]) for r in 1:nb_rooms, u in Uw) for j in 1:nb_patients))
        println(file, "A folga da complexidade foi: $(JuMP.value(variable_by_name(model, "folga_complexidade")))")
        println(file, "A folga do volume foi: $(JuMP.value(variable_by_name(model, "folga_volume")))")
    end
end

# Function to create the robust mathematical model based on the input parameters and the chosen configuration (robust or deterministic)
function creating_robust(desvio_OR, desvio_PO, desvio_ICU, Γ1, Γ2, Γ3, nb_specialties, nb_patients, nb_rooms, nb_days, nb_shifts, capacidade_OR, 
                        capacidade_PO, capacidade_ICU, patient_by_specialty, MSS, pac_esperados, cplx_esperada, air, bid, cplx_paciente, tempo_espera, 
                        tempo_OR, tempo_PO, precisa_ICU, tempo_ICU, filename, delta)

    # Creating the model
    println("Creating the mathematical model...")
	init_time = time_ns()                                   # Setting the initial time to measure the execution time of the model creation
    model = Model(Gurobi.Optimizer)                         # Creating the model object using Gurobi as the solver
    set_optimizer_attribute(model, "TimeLimit", 3600)       # Setting a time limit of 3600 seconds (1 hour) for the optimization process
    set_optimizer_attribute(model, "IntFeasTol", 1e-6)      # Setting the integer feasibility tolerance to 1e-6
    set_optimizer_attribute(model, "Threads", 8)            # Setting the number of threads to 8 for parallel processing
    st = filename[11:length(filename)-4]                    # Extracting the instance name from the filename (removing the path and file extension)
    set_optimizer_attribute(model, "LogFile", "log_1_Spec_Delta_$(delta)_math-model_$(st)_Gamma1_$(Γ1)_Gamma2_$(Γ2)_Gamma3_$(Γ3).txt")  # Setting the log file name for the optimization process

    # Creating the sets ======================================================================================================================
    I = 1:nb_specialties                            # The set of surgical specialties
    J = 1:nb_patients                               # The set of all patients
    R = 1:nb_rooms                                  # The set of rooms
    U = 1:(nb_days * nb_shifts)                     # The set of time slots u (Days * Shifts)
    Uall = collect(U)

    # Criando subconjuntos de pacientes
    # TODO - Ajustar o valor de acordo com o tamanho da lista de espera
    J_by_i = [ (patient_by_specialty*(i-1)+1):(patient_by_specialty*i) for i in I ] # Subconjunto de pacientes por especialidade (index) 
    J_ICU = [j for j in J if precisa_ICU[j] == 1]   # The set of patients who need ICU care
        
    # Creating the working time slots (Uw) based on the number of shifts and the working days (Monday to Friday)
    # TODO - Alterar quando considerar somente 1 turno (manhã) ou 3 turnos (manhã, tarde e noite)
    nb_works_shifts = 2             # Number of working shifts (1: morning, 2: morning and afternoon, 3: morning, afternoon, and night)
    is_workday(d) = mod1(d, 7) <= 5 # Determining if the day d is a working day (Monday to Friday)
    # Creating the Uw vector for workdays and shifts
    Uw = [ (d-1)*nb_shifts + s for d in 1:nb_days for s in 1:nb_works_shifts if is_workday(d) ]
    # ========================================================================================================================================
    
    # Variables ==============================================================================================================================
    @variable(model, x[j in J, r in R, u in Uw], Bin)  # Patient j in room r at time slot u
    @variable(model, y[i in I, r in R, u in Uw], Bin)  # Specialty i in room r at time slot u]
    @variable(model, v[j in J, u in Uw], Bin)          # Patient j is assigned at time slot u
    @variable(model, δ[i in I, r in R, u in Uw], Bin)  # Allocation change variable (negative)
    
    # Robust variables - ORs
    @variable(model, λ[r in R, u in Uw] >= 0)          # Dual variables for OR capacity constraints
    @variable(model, π[j in J, r in R, u in Uw] >= 0)  # Dual variables for specialty assignment constraints
    
    # Robust variables - PO
    @variable(model, κ1[idx in eachindex(Uall)] >= 0)           # Dual variables for ICU capacity constraints
    @variable(model, ζ1[j in J, idx in eachindex(Uall)] >= 0)   # Dual variables for ICU specialty assignment constraints
    
    # Robust variables - ICU
    @variable(model, κ2[idx in eachindex(Uall)] >= 0)           # Dual variables for ICU capacity constraints
    @variable(model, ζ3[j in J_ICU, idx in eachindex(Uall)] >= 0)   # Dual variables for ICU specialty assignment constraints
    
    # Variáveis de folga para metas estratégicas
    @variable(model, s1 >= 0, base_name = "folga_complexidade")  # Folga para complexidade esperada
    @variable(model, s2 >= 0, base_name = "folga_volume")  # Folga para número de pacientes esperados
    # ========================================================================================================================================

    # Parameters =============================================================================================================================
    M = 500 # TODO - ALTERE PARA MUDAR O PESO DO BIG-M (Análise de sensibilidade) - 500 é o valor padrão, mas pode ser alterado para testar a sensibilidade do modelo
    Δ = delta  # Limite de mudanças na alocação de especialidades
    # ========================================================================================================================================

    # Função Objetivo - Tempo de espera agregado dos pacientes + Penalidade por não atender as metas estratégicas
    pen = (nb_days*nb_shifts) + 1   # Penalidade por não alocar um paciente (tempo de espera máximo + 1)
    @objective(model, Min, sum((tempo_espera[j]+u)*v[j,u] for j in J, u in Uw) + sum((pen+tempo_espera[j])*(1-sum(v[j,u] for u in Uw)) for j in J)
                                + M*(s1 + s2))  # Penalidade por não atender as metas estratégicas

    # Desempenho esperado - Metas estratégicas que se deseja atingir (complexidade esperada e número de pacientes esperados)
    @constraint(model, sum(cplx_paciente[j] * sum(v[j,u] for u in Uw) for j in J) >= cplx_esperada - s1)
    @constraint(model, sum(v[j,u] for j in J, u in Uw) >= pac_esperados - s2)

    # Restrições (4 e 5) - Cada paciente é atendido no máximo uma vez no horizonte de planejamento
    @constraint(model, [j in J, u in Uw], sum(x[j,r,u] for r in R) == v[j,u])
    @constraint(model, [j in J], sum(v[j,u] for u in Uw) <= 1)
 
    # Restrições (29, 30, 9 e 10) - Capacidade das salas e atribuição de especialidades as salas
    @constraint(model, [r in R, u in Uw], sum(tempo_OR[j]*x[j, r, u] for j in J) + Γ1 * λ[r,u] + sum(π[j,r,u] for j in J) <= capacidade_OR) # Cada sala atende no máximo a capacidade fixa de tempo de sala de cirurgia
    @constraint(model, [j in J, r in R, u in Uw], λ[r,u] + π[j,r,u] >= desvio_OR[j]*x[j,r,u]) 
    @constraint(model, [r in R, u in Uw], sum(y[i, r, u] for i in I) <= 1) # Cada sala atende no máximo uma especialidade por turno # TODO - ALTERE ESSA RESTRIÇÃO PARA PERMITIR 1 OU 2 ESPECIALIDADES POR SALA
    @constraint(model, [i in I, j in J_by_i[i], r in R, u in Uw], x[j,r,u] <= y[i,r,u])  # Atribuindo pacientes a especialidades
    # for i in I, r in R, u in Uw
    #     Ji = J_by_i[i]
    #     @constraint(model, [j in Ji], x[j,r,u] <= y[i,r,u])  # No máximo 6 pacientes por sala, dado que o menor tempo de cirurgia é 1h
    # end

    # Restrições (11 e 12) - Disponibilidade de especialidades por sala e turno
    @constraint(model, [i in I, r in R, u in Uw], y[i, r, u] <= air[i, r]) # Specialty-room availability
    # for i in I, r in R, u in Uw
    #     @constraint(model, y[i, r, u] <= air[i, r]) # Specialty-room availability
    # end
    for i in I, d in 1:nb_days, r in R
        if is_workday(d)
            u1 = (d-1)*nb_shifts + 1
            u2 = (d-1)*nb_shifts + 2
            @constraint(model, y[i, r, u1] <= bid[i,d])
            @constraint(model, y[i, r, u2] <= bid[i,d])
        end
    end
    
    # Restrições (13, 14 e 15) - Limitar mudanças na alocação de especialidades por sala e turno
    @constraint(model, [i in I, r in R, u in Uw], - y[i, r, u] + MSS[i, r, u] <= δ[i, r, u]) # Contando o número de mudanças na alocação de especialidades (adicionando ou removendo especialidades)
    @constraint(model, [i in I, r in R, u in Uw], y[i, r, u] - MSS[i, r, u] <= δ[i, r, u])   
    @constraint(model, sum(δ[i, r, u] for i in I, r in R, u in Uw) <= Δ)  # Limitar o número de mudanças na alocação de especialidades

    # Restrições (13 e 14) - Capacidade de leitos de UTI e de recuperação pós-operatória
    W_icu = [Int[] for j in J, u in Uall]                   # Time windows for ICU capacity constraints (nominal time)
    W_icu_desvio = [Int[] for j in J, u in Uall]            # Time windows for ICU capacity constraints (deviation time)
    W_po_noicu = [Int[] for j in J, u in Uall]              # Time windows for PO capacity constraints (nominal time) for patients who do not need ICU care
    W_po_noicu_desvio = [Int[] for j in J, u in Uall]       # Time windows for PO capacity constraints (deviation time) for patients who do not need ICU care
    W_po_aftericu = [Int[] for j in J, u in Uall]           # Time windows for PO capacity constraints (nominal time) for patients who need ICU care
    W_po_aftericu_desvio = [Int[] for j in J, u in Uall]    # Time windows for PO capacity constraints (deviation time) for patients who need ICU care
    for j in J, (idx,u) in pairs(Uall)
        # ICU: u0 in (u-tempo_ICU, u] ou u0 in (u - tempo_ICU - desvio_ICU, u - tempo_ICU]
        lo = u - tempo_ICU[j]                               # Lower bound of the time window for ICU capacity constraints
        hi = u                                              # Upper bound of the time window for ICU capacity constraints
        W_icu[j,idx] = [u0 for u0 in Uw if lo < u0 <= hi]   # Time windows for ICU capacity constraints (nominal time)
        W_icu_desvio[j,idx] = [u0 for u0 in Uw if lo - desvio_ICU[j] < u0 <= hi - tempo_ICU[j]] # Time windows for ICU capacity constraints (deviation time)

        # PO sem ICU: u0 in (u-tempo_PO, u] ou u0 in (u - tempo_PO - desvio_PO, u - tempo_PO]
        lo = u - tempo_PO[j]                                    # Lower bound of the time window for PO capacity constraints for patients who do not need ICU care
        hi = u                                                  # Upper bound of the time window for PO capacity constraints for patients who do not need ICU care
        W_po_noicu[j,idx] = [u0 for u0 in Uw if lo < u0 <= hi]  # Time windows for PO capacity constraints for patients who do not need ICU care (nominal time)
        W_po_noicu_desvio[j,idx] = [u0 for u0 in Uw if lo - desvio_PO[j] < u0 <= hi - tempo_PO[j]]  # Time windows for PO capacity constraints for patients who do not need ICU care (deviation time)

        # PO após ICU: u0 in (u - tempo_PO - tempo_ICU, u - tempo_ICU] ou u0 in (u - tempo_PO - desvio_PO - tempo_ICU, u - tempo_PO - tempo_ICU]
        lo = u - tempo_PO[j] - tempo_ICU[j]                         # Lower bound of the time window for PO capacity constraints for patients who need ICU care
        hi = u - tempo_ICU[j]                                       # Upper bound of the time window for PO capacity constraints for patients who need ICU care
        W_po_aftericu[j,idx] = [u0 for u0 in Uw if lo < u0 <= hi]   # Time windows for PO capacity constraints for patients who need ICU care (nominal time)
        # W_po_aftericu_desvio[j,idx] = [u0 for u0 in Uw if lo - desvio_PO[j] - desvio_ICU[j] < u0 <= hi - tempo_PO[j]]
        W_po_aftericu_desvio[j,idx] = [u0 for u0 in Uw if lo - desvio_PO[j] < u0 <= hi - tempo_PO[j]]   # Time windows for PO capacity constraints for patients who need ICU care (deviation time)
    end

    # Restrições (45 e 46) - ICU constraints with robustness
    @constraint(model, [idx in eachindex(Uall)], sum(precisa_ICU[j]*sum(v[j,u0] for u0 in W_icu[j,idx]) for j in J_ICU ) + Γ3*κ2[idx] + sum(precisa_ICU[j]*ζ3[j,idx] for j in J_ICU) <= capacidade_ICU)
    @constraint(model, [j in J_ICU, idx in eachindex(Uall)], κ2[idx] + ζ3[j,idx] >= sum( v[j,u0] for u0 in W_icu_desvio[j,idx] ) )
    # for j in J_ICU, idx in eachindex(Uall)
    #     # for u0 in W_icu_desvio[j,idx]
    #     @constraint(model, κ2[idx] + ζ3[j,idx] >= sum( v[j,u0] for u0 in W_icu_desvio[j,idx] ) )
    #     # end
    # end

    # Restrições (37 e 38) - PO constraints with robustness
    @constraint(model, [idx in eachindex(Uall)], sum((1-precisa_ICU[j]) * sum(v[j,u0] for u0 in W_po_noicu[j,idx]) for j in J) + sum(precisa_ICU[j] * sum(v[j,u0] for u0 in W_po_aftericu[j,idx]) for j in J) + Γ2 * κ1[idx] + sum(ζ1[j,idx] for j in J) <= capacidade_PO)
    @constraint(model, [j in J, idx in eachindex(Uall)], κ1[idx] + ζ1[j,idx] >= precisa_ICU[j] * sum(v[j,u0] for u0 in W_po_aftericu_desvio[j,idx]) + (1 - precisa_ICU[j]) * sum(v[j,u0] for u0 in W_po_noicu_desvio[j,idx]))
    # for j in J, idx in eachindex(Uall)
    #     @constraint(model, κ1[idx] + ζ1[j,idx] >= precisa_ICU[j] * sum(v[j,u0] for u0 in W_po_aftericu_desvio[j,idx]) + (1 - precisa_ICU[j]) * sum(v[j,u0] for u0 in W_po_noicu_desvio[j,idx]))
    # end

    return model, init_time, x, y, v, δ
end