using JuMP
using Gurobi
using Random
using StatsBase
using XLSX, DataFrames
using ProgressMeter

include("read_instance.jl")
using .ReadInstance

function run_all(instance_test::String)
    # Parâmetros de robustez e relaxamento do MSS estratégico
    delta = [11, 33, 55]
    gamma1 = [0, 1, 2]
    gamma2 = [0, 4, 8]
    gamma3 = [0, 2, 4]

    #
    for d in delta, i in gamma1, j in gamma2, k in gamma3, l in 1:10
        # Executando a heurística
        obj, time = greedy_solution("Instances/$instance_test", "resultado_paper2_MSS_base.txt", i, j, k, d, 15, 10, l)
        
        # Salvando as informações em um arquivo externo
        open("ALNS_1spec_Delta_$(d)_resultado_compilado_$(instance_test)_G1_$(i)_G2_$(j)_G3_$(k).txt", "a") do file
            println(file, "Rodada $l -- Obj: ", obj, " - Time: ", time* 1e-9, " s")
        end
    end
end

function run_instances()
    # Função para automatizar a execução das instâncias
    # run_all("instance_030_33_33_33.txt")
    # run_all("instance_030_60_20_20.txt")
    # run_all("instance_030_20_60_20.txt")
    # run_all("instance_030_20_20_60.txt")
    #
    # run_all("instance_040_33_33_33.txt")
    # run_all("instance_040_60_20_20.txt")
    # run_all("instance_040_20_60_20.txt")
    # run_all("instance_040_20_20_60.txt")
    #
    # run_all("instance_050_33_33_33.txt")
    # run_all("instance_050_60_20_20.txt")
    # run_all("instance_050_20_60_20.txt")
    # run_all("instance_050_20_20_60.txt")
end

function greedy_solution(filename::String, filename2::String, Γ1::Int64, Γ2::Int64, Γ3::Int64, delta::Int64, T1::Int64, T2::Int64, rodada::Int64)
    # LENDO A INSTÂNCIA
    desvio_OR, desvio_PO, desvio_ICU, nb_specialties, nb_patients, nb_rooms, nb_days, nb_shifts, capacidade_OR, capacidade_PO, 
    capacidade_ICU, patient_by_specialty, MSS, pac_esperados, cplx_esperada, air, bid, cplx_paciente, tempo_espera, tempo_OR, 
    tempo_PO, precisa_ICU, tempo_ICU = ReadInstance.read_instance(filename, filename2)

    # Iniciando o contador de tempo
    init_time = time_ns()

    # Definindo os conjuntos de interesse
    U = 1:(nb_days * nb_shifts) # Time slots (Days * Shifts)                            # The set of time slots (days * shifts)
    Uw = [ (d-1)*nb_shifts + s for d in 1:nb_days for s in 1:2 if mod1(d, 7) <= 5 ]     # The set of time slots (days * shifts) for weekdays (Monday to Friday)
    I = 1:nb_specialties                                                                # The set of specialties 
    J = 1:nb_patients                                                                   # The set of patients
    R = 1:nb_rooms                                                                      # The set of rooms

    # Definindo as variáveis de decisão 
    x_sol = zeros(Int64, nb_patients, nb_rooms, maximum(Uw))                            # The vector x_sol[j,r,u] indicates whether patient j is allocated in room r at time slot u (1) or not (0)
    v_sol = zeros(Int64, nb_patients, maximum(Uw))                                      # The vector v_sol[j,u] indicates whether patient j is allocated in time slot u (1) or not (0)
    y_sol = MSS                                                                         # The vector y_sol[i,r,u] indicates whether specialty i is allocated in room r at time slot u (1) or not (0) - Fixado de acordo o MSS

    # Definindo os vetores de ocupação nominal e de desvio para cada recurso
    ICU_ocupacao_nominal = zeros(Int64, nb_days*nb_shifts)                              # ICU occupation nominal vector (number of patients in ICU at each time slot)
    ICU_ocupacao_desvio = zeros(Int64, nb_days*nb_shifts)                               # ICU occupation deviation vector (number of patients in ICU at each time slot that can have their ICU time increased)
    PO_ocupacao_nominal = zeros(Int64, nb_days*nb_shifts)                               # PO occupation nominal vector (number of patients in PO at each time slot)
    PO_ocupacao_desvio = zeros(Int64, nb_days*nb_shifts)                                # PO occupation deviation vector (number of patients in PO at each time slot that can have their PO time increased) 
    OR_ocupacao_nominal = Dict((r, u) => 0.0 for r in R, u in Uw)                       # OR occupation nominal dictionary (number of patients in OR at each time slot for each room)
    OR_ocupacao_desvio = Dict((r, u) => [] for r in R, u in Uw)                         # OR occupation deviation dictionary (list of patients in OR at each time slot for each room that can have their OR time increased)

    # Ordenar os pacientes de acordo com o tempo de espera
    pacientes_ordenados = Dict()
    for i in I
        pacientes_ordenados[i] = [(j, tempo_espera[j]) for j in (patient_by_specialty*(i-1)+1):(patient_by_specialty*i)]    # Patients 1:i belongs to first specialty i, i+1:2i belongs to second specialty and so on... 
        sort!(pacientes_ordenados[i], by = x -> x[2], rev = true)   
    end
    
    # INICIANDO A HEURÍSTICA GREEDY
    obj_solution = 0                                # Objective value of the solution
    complexity_score_obtained = 0                   # Complexity score of the solution
    check_allocation = zeros(Int64, nb_patients)    # Vector to check if a patient has been allocated (1) or not (0)
    ############################################################################################################################################
    for i in I                                                      # Verifica-se cada especialidade
        for r in R, u in Uw                                         # Verifica-se cada sala e cada turno de trabalho
            # PARA CADA ESPECIALIDADE, SALA E TURNO, VERIFICA-SE SE HÁ UMA ALOCAÇÃO NO MSS
            if y_sol[i, r, u] > 0.9                                 # Caso haja uma alocação no MSS (1), verifica-se se há pacientes da especialidade i para alocar na sala r no turno u 
                # PROCURA-SE O PRIMEIRO PACIENTE VÁLIDO PARA ALOCAÇÃO (first fit LOGIC)
                for paciente in pacientes_ordenados[i]
                    # (0) VERIFICA-SE O ESTADO DO PACIENTE, CASO JÁ TENHA SIDO ALOCADO (1), PASSA PARA O PRÓXIMO PACIENTE
                    j = paciente[1]
                    check_allocation[j] == 1 && continue

                    # (1) VERIFICA-SE A CAPACIDADE DA OR, CASO A OCUPAÇÃO NOMINAL + DESVIO + TEMPO DE OPERAÇÃO DO PACIENTE J SEJA MAIOR QUE A CAPACIDADE DA OR, PASSA PARA O PRÓXIMO PACIENTE
                    # -- Contabilizando os desvios dos pacientes alocados ao tupla (i, r, u)
                    # ---- Durante o processo, verifica-se se o paciente j tem um desvio maior que o menor desvio dos pacientes alocados ao tupla (i, r, u)
                    # ---- Caso o tenha, remove-se o paciente com menor desvio e adiciona-se o paciente j
                    j_remove_position = nothing
                    desvio_calculado = 0.0
                    if Γ1 > 0                                               # Verifica-se se há possibilidade de desvio (Γ1 > 0), caso contrário, o desvio calculado é 0
                        if length(OR_ocupacao_desvio[r,u]) < Γ1             # Verifica-se se o número de pacientes alocados ao tupla (i, r, u) é menor que Γ1, caso seja, o desvio calculado é a soma dos desvios dos pacientes alocados ao tupla (i, r, u) mais o desvio do paciente j
                            if length(OR_ocupacao_desvio[r,u]) == 0         # Caso não haja pacientes alocados ao tupla (i, r, u), o desvio calculado é o desvio do paciente j
                                desvio_calculado = desvio_OR[j]
                            else                                            # Caso haja pacientes alocados ao tupla (i, r, u), o desvio calculado é a soma dos desvios dos pacientes alocados ao tupla (i, r, u) mais o desvio do paciente j
                                desvio_calculado = sum(desvio_OR[p] for p in OR_ocupacao_desvio[r,u]) + desvio_OR[j]
                            end
                        else                                                # Caso o número de pacientes alocados ao tupla (i, r, u) seja maior ou igual a Γ1
                            desvio_calculado = sum(desvio_OR[p] for p in OR_ocupacao_desvio[r,u])           # Calcula-se o desvio total 
                            desvio_min, pos_min = findmin(desvio_OR[p] for p in OR_ocupacao_desvio[r,u])    # Encontra-se o menor desvio e a posição na lista com menor desvio
                            if desvio_OR[j] > desvio_min                                                    # --- Caso o paciente j possua o desvio maior que o menor desvio
                                desvio_calculado = desvio_calculado - desvio_min + desvio_OR[j]             # --- Recalcula-se o desvio total, removendo o menor desvio e adicionando o desvio do paciente j
                                j_remove_position = pos_min                                                 # --- Armazena-se a posição do paciente com menor desvio para remoção posterior (caso necessário)
                            end
                        end
                    end    
                    
                    # -- Calculando a ocupação total
                    # ---- Aqui, a ocupação da sala deve respeitar a capacidade total (hard constraint), i.e., OR_ocupacao_nominal[r,u] + desvio + tempo_OR[j] <= capacidade_OR
                    ocupacao_total = OR_ocupacao_nominal[r,u] + desvio_calculado + tempo_OR[j]  # Calcula-se a ocupação total da sala r no turno u, considerando a ocupação nominal, o desvio calculado e o tempo de operação do paciente j
                    ocupacao_total > capacidade_OR && continue                                  # Caso a ocupação total seja maior que a capacidade da sala, passa-se para o próximo paciente

                    # (2) Verificar a capacidade do ICU (se aplicável)
                    icu_availability = true         # Inicialmente, assume-se que há disponibilidade de leitos no ICU
                    u_ICU_fim_nominal = 0           # Inicia-se a variável que armazenará o último turno nominal do ICU para o paciente j
                    u_ICU_fim_desvio = 0            # Inicia-se a variável que armazenará o último turno com desvio do ICU para o paciente j
                    if precisa_ICU[j] == 1          # ---- Caso o paciente j necessite de leito no ICU, verifica-se a disponibilidade de leitos no ICU
                        # -- Criando as janelas de tempo
                        u_ICU_fim_nominal = u + tempo_ICU[j] - 1                # A primeira janela de tempo do ICU é o turno u até o turno u + tempo_ICU[j] - 1 (nominal) [O PACIENTE OCUPA O LEITO JÁ NO TEMPO u]
                        u_ICU_fim_desvio = u_ICU_fim_nominal + desvio_ICU[j]    # A segunda janela de tempo do ICU é o turno u + tempo_ICU[j] até o turno u + tempo_ICU[j] + desvio_ICU[j] (com desvio) [O PACIENTE OCUPA O LEITO JÁ NO TEMPO u]
 
                        # -- Verificando a capacidade nominal
                        for u1 in u:u_ICU_fim_nominal                           # Verifica-se a capacidade do ICU para cada turno da primeira janela de tempo (nominal) [u1 pode superar |U|, por isso trava em u1 > length(U)]
                            u1 > length(U) && break                             # ---- Se já foram verificados todoos os turnos do horizonte de planejamento, acabou a verificação!
                            nb_piores_casos = min(ICU_ocupacao_desvio[u1], Γ3)  # ---- Verifica-se o número de pacientes que podem ter seu tempo de ICU prolongado (desvio) até o turno u1, limitado pelo parâmetro Γ3
                            if (ICU_ocupacao_nominal[u1] + 1 + nb_piores_casos) > capacidade_ICU    # ------ Verifica a capacidade dos leitos no momento u1
                                icu_availability = false                                            # ------ Determina a disponibilidade dos leitos, caso não haja disponibilidade, passa-se para o próximo paciente
                                break                                                               # ------ Finaliza a verificação da capacidade do ICU, pois já foi determinado que não há disponibilidade de leitos
                            end
                        end
                        icu_availability || continue                            # Se não há disponibilidade, não há alocação

                        # -- Verificando a capacidade com desvio
                        if Γ3 > 0                                               # Caso haja possibilidade de desvio (Γ3 > 0)
                            for u1 in (u_ICU_fim_nominal + 1):u_ICU_fim_desvio  # ---- Verifica-se a capacidade do ICU para cada turno da segunda janela de tempo (com desvio) [u1 pode superar |U|, por isso trava em u1 > length(U)]
                                # -- Definindo o turno de avaliação e os piores casos
                                u1 > length(U) && break                         # ---- Verifica-se somente até a janela de tempo |U|, i.e. o horizonte de planejamento
                                nb_piores_casos = min(ICU_ocupacao_desvio[u1] + 1, Γ3)             # ------ Determina-se o número de piores casos. O paciente j integra a lista de piores casos, por isso o +1. O número de piores casos é limitado pelo parâmetro Γ3
                                if (ICU_ocupacao_nominal[u1] + nb_piores_casos) > capacidade_ICU   # ------ Verifica a capacidade dos leitos no momento u1
                                    icu_availability = false                                       # ------ Determina a disponibilidade dos leitos, false caso não haja disponibilidade, passa-se para o próximo paciente
                                    break                                                          # ------ Finaliza a verificação da capacidade do ICU, pois já foi determinado que não há disponibilidade de leitos
                                end
                            end
                        end
                    end

                    # (3) Verificar a capacidade do PO
                    po_availability = true                           # Inicialmente, assume-se que há disponibilidade de leitos no PO
                    u_PO_init_nominal = 0; u_PO_fim_nominal = 0      # Inicia-se a variável que armazenará o último turno nominal do ICU para o paciente j
                    u_PO_init_desvio = 0;  u_PO_fim_desvio = 0       # Inicia-se a variável que armazenará o último turno com desvio do ICU para o paciente j
                    if precisa_ICU[j] == 1                           # As janelas de tempo do PO dependem da necessidade de leito no ICU
                        # -- Criando as janelas de tempo             # Caso o paciente j necessite de leito no ICU, a primeira janela de tempo do PO é o turno u + tempo_ICU[j] até o turno u + tempo_ICU[j] + tempo_PO[j] - 1 (nominal)
                        u_PO_init_nominal = u + tempo_ICU[j]                        # A primeira janela de tempo do PO é o turno u + tempo_ICU[j] até o turno u + tempo_ICU[j] + tempo_PO[j] - 1 (nominal) 
                                                                                    # -- [O PACIENTE OCUPA O LEITO JÁ NO TEMPO u + tempo_ICU[j], UMA VEZ QUE O LEITO DE ICU É OCUPADO ATÉ O TURNO u + tempo_ICU[j] - 1]
                        u_PO_fim_nominal = u_PO_init_nominal + tempo_PO[j] - 1      # A segunda janela de tempo do PO é o turno u + tempo_ICU[j] + tempo_PO[j] até o turno u + tempo_ICU[j] + tempo_PO[j] + desvio_PO[j] (com desvio) 
                                                                                    # -- [O PACIENTE OCUPA O LEITO JÁ NO TEMPO u + tempo_ICU[j] + tempo_PO[j], UMA VEZ QUE O LEITO DE PO É OCUPADO ATÉ O TURNO u + tempo_ICU[j] + tempo_PO[j] - 1]
                        u_PO_init_desvio = u_PO_fim_nominal + 1                     # A segunda janela de tempo do PO é o turno u + tempo_ICU[j] + tempo_PO[j] até o turno u + tempo_ICU[j] + tempo_PO[j] + desvio_PO[j] (com desvio)
                        u_PO_fim_desvio = u_PO_fim_nominal + desvio_PO[j]           # A segunda janela de tempo do PO é o turno u + tempo_ICU[j] + tempo_PO[j] até o turno u + tempo_ICU[j] + tempo_PO[j] + desvio_PO[j] (com desvio)
                    else
                        # -- Criando as janelas de tempo            # Caso o paciente j não necessite de leito no ICU, a primeira janela de tempo do PO é o turno u até o turno u + tempo_PO[j] - 1 (nominal) [MESMA LÓGICA DE ICU]
                        u_PO_init_nominal = u                       
                        u_PO_fim_nominal = u + tempo_PO[j] - 1
                        u_PO_init_desvio = u_PO_fim_nominal + 1
                        u_PO_fim_desvio = u_PO_fim_nominal + desvio_PO[j]
                    end
                    
                    # -- Verificando a capacidade nominal
                    for u1 in u_PO_init_nominal:u_PO_fim_nominal         # Verifica-se a capacidade do ICU para cada turno da primeira janela de tempo (nominal) [u1 pode superar |U|, por isso trava em u1 > length(U)]
                        u1 > length(U) && break                             # ---- Se já foram verificados todoos os turnos do horizonte de planejamento, acabou a verificação!
                        nb_piores_casos = min(PO_ocupacao_desvio[u1], Γ2)   # ---- Verifica-se o número de pacientes que podem ter seu tempo de ICU prolongado (desvio) até o turno u1, limitado pelo parâmetro Γ2
                        if (PO_ocupacao_nominal[u1] + nb_piores_casos + 1) > capacidade_PO   # ------ Verifica-SE a capacidade dos leitos no momento u1
                            po_availability = false                                          # ------ Determina a disponibilidade dos leitos, false caso não haja disponibilidade, passa-se para o próximo paciente
                            break
                        end
                    end
                    po_availability || continue                             # Se não há disponibilidade, não há alocação

                    # -- Verificando a capacidade com desvio
                    if Γ2 > 0                                                                # Caso haja possibilidade de desvio (Γ2 > 0)
                        for u1 in u_PO_init_desvio:u_PO_fim_desvio                           # --- Verifica-se a capacidade do PO para cada turno da segunda janela de tempo (com desvio) 
                            # -- Definindo o turno de avaliação e os piores casos
                            u1 > length(U) && break                                          # ---- [u1 pode superar |U|, por isso trava em u1 > length(U)]            
                            nb_piores_casos = min(PO_ocupacao_desvio[u1] + 1, Γ2)            # ---- Determina-se o número de piores casos. O paciente j integra a lista de piores casos, por isso o +1. O número de piores casos é limitado pelo parâmetro Γ2
                            if (PO_ocupacao_nominal[u1] + nb_piores_casos) > capacidade_PO   # ------ Verifica a capacidade dos leitos no momento u1
                                po_availability = false                                      # ------ Determina a disponibilidade dos leitos
                                break
                            end
                        end
                    end
                    
                    # Inserindo o paciente e atualizando os parâmetros
                    check_allocation[j] = 1                                         # Atualizando o parâmetro de verificação de alocação do paciente j
                    x_sol[j, r, u] = 1                                              # Atualizando a variável de decisão de alocação (x_sol[j,r,u] = 1)
                    v_sol[j, u] = 1                                                 # Atualizando a variável de decisão de alocação (v_sol[j,u] = 1)    
                    obj_solution += paciente[2] + u                                 # Atualizando o valor objetivo da solução (obj_solution = obj_solution + tempo_espera[j] + u)
                    complexity_score_obtained += cplx_paciente[j]                   # Atualizando o score de complexidade da solução (complexity_score_obtained = complexity_score_obtained + cplx_paciente[j])
                    # -- Atualizando os parâmetros da OR
                    OR_ocupacao_nominal[r,u] += tempo_OR[j]                         # Atualizando o tempo de ocupação da OR
                    if isnothing(j_remove_position) && Γ1 > 0
                        push!(OR_ocupacao_desvio[r, u], j)                          # Atualizando a lista de piores desvios, apenas adicionando o paciente j
                    elseif !isnothing(j_remove_position) && Γ1 > 0
                        deleteat!(OR_ocupacao_desvio[r, u], j_remove_position)      # Remover-se o paciente de menor desvio
                        push!(OR_ocupacao_desvio[r, u], j)                          # Adiciona-se o paciente j
                    end

                    # -- Atualizando os parâmetros do ICU
                    if precisa_ICU[j] == 1                      # Se o paciente irá usar o leito de ICU, atualiza-se os parâmetros de ocupação
                        for u1 in u:u_ICU_fim_desvio            # Percorre-se a janela de ocupação do paciente até o fim do desvio (i.e., pior caso de ocupação)
                            u1 > length(U) && break             # Verifica-se a janela de tempo para estar dentro do horizonte de planejamento
                            if u1 <= u_ICU_fim_nominal          # Caso a janela verificada seja a nominal
                                ICU_ocupacao_nominal[u1] += 1
                            else                                # Caso a janela verificada seja o desvio
                                ICU_ocupacao_desvio[u1] += 1
                            end
                        end
                    end

                    # -- Atualizando os parâmetros do PO
                    for u1 in u_PO_init_nominal:u_PO_fim_desvio  # Percorre-se a janela de ocupação do paciente até o fim do desvio (i.e., pior caso de ocupação)
                        u1 > length(U) && break
                        if u1 <= u_PO_fim_nominal               # Caso a janela verificada seja a nominal
                            PO_ocupacao_nominal[u1] += 1
                        else                                    # Caso a janela verificada seja o desvio
                            PO_ocupacao_desvio[u1] += 1
                        end
                    end
                end
            end
        end
    end

    # Compilando as métricas da solução obtida
    obj_solution += sum((tempo_espera[j] + length(U) + 1) for j in J if check_allocation[j] == 0)   # Contabilizando os pacientes que não foram alocados
    nb_patients_obtained = sum(check_allocation[j] for j in J)                                      # Contabilizando o número de pacientes atendidos
    obj_solution += max(0, (500*(cplx_esperada - complexity_score_obtained)))                       # Contabilizando a penalidade de complexidade (caso a complexidade obtida seja menor que a esperada)
    obj_solution += max(0, 500*(pac_esperados - nb_patients_obtained))                              # Contabilizando a penalidade de volume (caso o número de pacientes atendidos seja menor que o esperado)

    # Imprimindo os resultados da heurística no terminal
    println("\n\nDelta -- $(delta)")
    println("\n\nInitial solution")
    println("Obj_value: $(obj_solution)")
    println("Nb. patients allocated: ", nb_patients_obtained)
    println("Score of complexity obtained: ", complexity_score_obtained)
    println(" --------- Tempo decorrido da heurística: ", (time_ns() - init_time) * 1e-9, "s")

    # Executando a heurística
    model_robust, _, best_obj_value, x_best, y_best, v_best, _, iteracao, operador_utilizacao, operador_melhoria = ALNS_robust(obj_solution, desvio_OR, desvio_PO, desvio_ICU, Γ1, Γ2, Γ3, nb_specialties, 
                nb_patients, nb_rooms, nb_days, nb_shifts, capacidade_OR, capacidade_PO, capacidade_ICU, patient_by_specialty, MSS, pac_esperados, cplx_esperada, air, bid, cplx_paciente, tempo_espera, 
                tempo_OR, tempo_PO, precisa_ICU, tempo_ICU, x_sol, y_sol, v_sol, delta, T1, T2, filename, rodada, init_time)


    # Calcular complexidade e volume e comparar com os padrões
    complexity_score_robust = sum(cplx_paciente[j] * v_best[j,u] for j in J, u in Uw)
    volume_robust = sum(v_best[j,u] for j in J, u in Uw)
    println("\n\nSolução robusta obtida pela heurística ALNS:")
    println("Objective Value: ", best_obj_value)
    println("Complexidade: $complexity_score_robust")
    println("Volume: $volume_robust")
    println("Comparação com os padrões: volume esperado = $(pac_esperados - volume_robust), complexidade esperada = $(cplx_esperada - complexity_score_robust))")    
    tempo_decorrido_heuristica = (time_ns() - init_time) 
    println("Tempo decorrido da heurística: ", tempo_decorrido_heuristica * 1e-9, "s")


    # Salvando as informações em um arquivo externo - Apenas as informações resumidas da heurística
    st = filename[11:length(filename)-4]
    open("ALNS_1spec_Delta_$(delta)_results_$(st)_T1_$(T1)_T2_$(T2)_G1_$(Γ1)_G2_$(Γ2)_G3_$(Γ3).txt", "a") do file
        println(file, "Rodada: $rodada")
        println(file, "Complexidade: $complexity_score_robust") 
        println(file, "Volume: $volume_robust")
        println(file, "Objective Value: ", best_obj_value)
        println(file, "Tempo decorrido da heuristica: ", tempo_decorrido_heuristica * 1e-9, "s")
        println(file, "Número de iteracoes: ", iteracao)
        println(file, "Utilização dos operadores: ", operador_utilizacao)
        println(file, "Melhoria com os operadores: ", operador_melhoria)
        println(file, "\n") # Adiciona um espaço extra entre rodadas
    end

    # Salvando as informações em um arquivo externo - Apenas as informações detalhadas da heurística
    open("ALNS_1spec_Delta_$(delta)_detailed_results_$(st)_T1_$(T1)_T2_$(T2)_G1_$(Γ1)_G2_$(Γ2)_G3_$(Γ3).txt", "a") do file
        write(file, "\n\n Variáveis de decisão -- rodada $rodada\n")
        write(file, "\ny_sol: \n")
        for i in I, r in R, u in Uw
            if y_best[i, r, u] == 1
                write(file, "\n y[$i, $r, $u] = 1")
            end
        end
        write(file, "\nx_sol: \n")
        for j in J, r in R, u in Uw
            if x_best[j, r, u] == 1
                write(file, "\n x[$j, $r, $u] = 1")
            end
        end
    end
    println("\n\nFIM!")

    return best_obj_value, tempo_decorrido_heuristica
end

function ALNS_robust(obj_value, desvio_OR, desvio_PO, desvio_ICU, Γ1, Γ2, Γ3, nb_specialties, nb_patients, nb_rooms, nb_days, nb_shifts, capacidade_OR, 
                        capacidade_PO, capacidade_ICU, patient_by_specialty, MSS, pac_esperados, cplx_esperada, air, bid, cplx_paciente, tempo_espera, 
                        tempo_OR, tempo_PO, precisa_ICU, tempo_ICU, x_sol, y_sol, v_sol, delta, T1, T2, filename, rodada, init_time)

    println("building robust mathematical model...")
    Random.seed!(round(Int, time() * 1000))
    # Random.seed!(123)

    # Creating the model
    model = Model(Gurobi.Optimizer)
    set_optimizer_attribute(model, "TimeLimit", 10)         # Setting a time limit of 10 seconds for the optimization process (It was checked 20s and 30s)
    set_optimizer_attribute(model, "IntFeasTol", 1e-6)      # Setting the integer feasibility tolerance to 1e-6
    # set_optimizer_attribute(model, "MIPStart", 0)         # Desativa o uso de starts anteriores
    st = filename[11:length(filename)-4]
    set_optimizer_attribute(model, "LogFile", "log_1spec_ALNS_$(st)_rodada_$(rodada)_Delta_$(delta)_Gamma1_$(Γ1)_Gamma2_$(Γ2)_Gamma3_$(Γ3)_T1_$(T1)_T2_$(T2).txt")
    set_optimizer_attribute(model, "LogToConsole", 0)       # Set the log output to the console to 0 (no output to console)
    # set_optimizer_attribute(model, "LPWarmStart", 0)      # Remove warm start para LP models
    set_optimizer_attribute(model, "Threads", 8)            # Setting the number of threads to 8 for parallel processing
    # set_optimizer_attribute(model, "MIPFocus", 1)         # Setting the MIP focus to 1 (focus on finding feasible solutions)

    # Creating the sets ======================================================================================================================
    I = 1:nb_specialties                            # The set of surgical specialties
    J = 1:nb_patients                               # The set of all patients
    R = 1:nb_rooms                                  # The set of rooms
    U = 1:(nb_days * nb_shifts)                     # The set of time slots u (Days * Shifts)
    Uall = collect(U)

    # Criando subconjuntos de pacientes
    # TODO - Ajustar o valor de acordo com o tamanho da lista de espera
    J_by_i = [ (patient_by_specialty*(i-1)+1):(patient_by_specialty*i) for i in I ] # Subconjunto de pacientes por especialidade (index) # TODO - Ajustar o valor de acordo com o tamanho da lista de espera 
    J_ICU = [j for j in J if precisa_ICU[j] == 1]   # The set of patients who need ICU care
        
    # Creating the working time slots (Uw) based on the number of shifts and the working days (Monday to Friday)
    # TODO - Alterar quando considerar somente 1 turno (manhã) ou 3 turnos (manhã, tarde e noite)
    nb_works_shifts = 2             # Number of working shifts (1: morning, 2: morning and afternoon, 3: morning, afternoon, and night)
    is_workday(d) = mod1(d, 7) <= 5 # Determining if the day d is a working day (Monday to Friday)
    # Creating the Uw vector for workdays and shifts
    Uw = [ (d-1)*nb_shifts + s for d in 1:nb_days for s in 1:nb_works_shifts if is_workday(d) ]
    Dw = [d for d in 1:nb_days if is_workday(d)]
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
    pen = (nb_days*nb_shifts) + 1   # Penalidade para pacientes não alocados (tempo de espera + 1)
    @objective(model, Min, sum((tempo_espera[j]+u)*v[j,u] for j in J, u in Uw) + sum((pen+tempo_espera[j])*(1-sum(v[j,u] for u in Uw)) for j in J)  # Penalidade para pacientes os pacientes (não) alocados
                                + M*(s1 + s2))  # Penalidade por não atender as metas estratégicas

    # Desempenho esperado - Metas estratégicas que se deseja atingir (complexidade esperada e número de pacientes esperados)
    @constraint(model, sum(cplx_paciente[j] * sum(v[j,u] for u in Uw) for j in J) >= cplx_esperada - s1)
    @constraint(model, sum(v[j,u] for j in J, u in Uw) >= pac_esperados - s2)

    # Restrições (4 e 5) - Cada paciente é atendido no máximo uma vez no horizonte de planejamento
    @constraint(model, [j in J, u in Uw], sum(x[j,r,u] for r in R) == v[j,u])
    @constraint(model, [j in J], sum(v[j,u] for u in Uw) <= 1)

    # Restrições (29, 30, 9 e 10) - Capacidade das salas e atribuição de especialidades as salas
    @constraint(model, robustez_OR[r in R, u in Uw], sum(tempo_OR[j]*x[j, r, u] for j in J) + (Γ1 * λ[r,u]) + sum(π[j,r,u] for j in J) <= capacidade_OR) # Cada sala atende no máximo a capacidade fixa de tempo de sala de cirurgia
    @constraint(model, robustez_OR2[j in J, r in R, u in Uw], λ[r,u] + π[j,r,u] >= desvio_OR[j]*x[j,r,u])
    @constraint(model, [r in R, u in Uw], sum(y[i, r, u] for i in I) <= 1)  # Cada sala atende no máximo uma especialidade por turno # TODO - ALTERE ESSA RESTRIÇÃO PARA PERMITIR 1 OU 2 ESPECIALIDADES POR SALA    
    @constraint(model, [i in I, j in J_by_i[i], r in R, u in Uw], x[j,r,u] <= y[i,r,u])  # Atribuindo pacientes a especialidades
    # for i in I, r in R, u in Uw
    #     Ji = J_by_i[i]
    #     @constraint(model, [j in Ji], x[j,r,u] <= y[i,r,u])  # No máximo 6 pacientes por sala, dado que o menor tempo de cirurgia é 1h
    # end

    # Restrições (11 e 12) - Disponibilidade de especialidades por sala e turno
    @constraint(model, [i in I, r in R, u in Uw], y[i, r, u] <= air[i, r])  # Specialty-room availability
    for i in I, d in 1:nb_days, r in R                                      # Specialty-day availability
        if is_workday(d)
            u1 = (d-1)*nb_shifts + 1                        # Turno 1 do dia d
            u2 = (d-1)*nb_shifts + 2                        # Turno 2 do dia d
            @constraint(model, y[i, r, u1] <= bid[i,d])     # Permitir que a especialidade seja alocada ao turno (shift 1 e 2)
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
    @constraint(model, [j in J_ICU, idx in eachindex(Uall)], κ2[idx] + precisa_ICU[j]*ζ3[j,idx] >= sum( precisa_ICU[j]*v[j,u0] for u0 in W_icu_desvio[j,idx] ) )
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

    ################################################
    # CRIANDO A LÓGICA DA ALNS
    ################################################

    # Executando o ALNS heuristic
    println(" \n\n\n\n-- Executando o ALNS heuristic para reparar a solução...")    # Printing a message indicating the start of the ALNS heuristic to repair the solution
    
    # Determinando estruturas iniciais
    infeasible_solution = true                                                      # Setando a flag de solução inviável como verdadeira, para que o loop utilize apenas os operadores que não exploram a estrutura de solução do modelo matemático
    loop = 0                                                                        # Setando o contador de loop igual a zero (0), para que seja contabilizado o número de vezes que o algoritmo não melhora a melhor solução global
    iteracao = 1                                                                    # Setando o contador de iterações igual a um (1), para que seja contabilizado o número de vezes que o algoritmo é executado (1º execução já começa com 1)
    operador_utilizacao = zeros(Int64, 5)           # Vetor para controlar a utilização dos operadores de destruição (globalmente)
    operador_utilizacao_ciclo = zeros(Int64, 5)     # Vetor para controlar a utilização dos operadores de destruição (localmente)
    operador_melhoria = zeros(Int64, 5)             # Vetor para controlar o número de melhorias proporcionadas pelo operador de destruição (globalmente)
    operador_melhoria_ciclo = zeros(Int64, 5)       # Vetor para controlar o número de melhorias proporcionadas pelo operador de destruição (localmente)
    probabilidade_operador = [0.2 for op in 1:5]    # Vetor para controlar a probabilidade de seleção de um operador
    pesos_operador = [1.0 for op in 1:5]            # Vetor de pesos para cada operador
    
    # Criando variáveis para controlar informações do algoritmo
    x_best = 0                      # x_best - Salva a matriz de decisão x com as melhores escolhas encontradas pelo algoritmo
    y_best = 0                      # y_best - Salva a matriz de decisão y com as melhores escolhas encontradas pelo algoritmo
    v_best = 0                      # v_best - Salva a matriz de decisão v com as melhores escolhas encontradas pelo algoritmo
    best_obj_value = obj_value      # Salva a melhor F.O. encontrada pelo algoritmo (global)
    ciclo_obj_value = obj_value     # Salva a melhor F.O. encontrada pelo algoritmo (local)
    solucao_encontrada = 0          # Salva o F.O. da solução corrente
    destroy_operator = 0            # Salva o operador de destruição utilizado na iteração corrente

    # Estruturas para guardar o que foi unfixed na iteração anterior
    last_unfixed_y = Tuple{Int,Int,Int}[]   # (i,r,u)
    last_unfixed_x = Tuple{Int,Int,Int}[]   # (j,r,u)
    last_unfixed_v = Tuple{Int,Int}[]       # (j,u)
    
    # Fixando as Variáveis - O algoritmo explora as soluções de acordo com a solução encontrada na iteração anterior, portanto, as variáveis são fixadas de acordo com a solução corrente
    for u in Uw
        for r in 1:nb_rooms, i in I
            fix(y[i,r,u], y_sol[i,r,u]; force = true)
            set_start_value(y[i,r,u], y_sol[i,r,u])
        end
        for j in J
            fix(v[j,u], v_sol[j,u]; force = true)
            set_start_value(v[j,u], v_sol[j,u])
            for r in 1:nb_rooms
                fix(x[j,r,u], x_sol[j,r,u]; force = true)
                set_start_value(x[j,r,u], x_sol[j,r,u])
            end
        end
    end

    # Fixando a variável para controlar o reset no modelo matemático 
    reset = false

    # Comecando a lógica de destruição e reconstrução
    while loop < T1
        # Printing debug
        println("\n\n\n\n --------- Iteração $iteracao")
        println(" --------- Iterations without improvement: $loop")
        println(" --------- Best solution so far: $(best_obj_value)")
        println(" --------- Tempo decorrido da heurística: ", (time_ns() - init_time) * 1e-9, "s")
        
        # Selecionando os operadores
        if iteracao == 1 || reset == true || infeasible_solution == true
            # Como o operador 5 depende diretamente de informações do modelo matemático, ele não pode ser utilizado na primeira iteração, nem quando o modelo é resetado ou quando a solução corrente é inviável
            # A escolha não afeta a probabilidade de escolha dos operadores 1, 2, 3 e 4, que são independentes do modelo matemático
            destroy_operator = sample(1:4, Weights(probabilidade_operador[1:4]))
        else
            destroy_operator = sample(1:5, Weights(probabilidade_operador))
        end

        # Verificando se o modelo resetou
        if reset == true 
            infeasible_solution = true
            ciclo_obj_value = Inf
            reset = false
        end

        #
        println(" --------- Executando o operador de destruição $(destroy_operator) \n")
        ##################################################################
        if destroy_operator == 1
        ##################################################################
            # Destroy 1 - Remover uma especialidade da solução
            # -- 1º Step - Fixar as variáveis da iteração anterior
            refix_last_neighborhood!(x, y, v, x_sol, y_sol, v_sol, last_unfixed_x, last_unfixed_y, last_unfixed_v)
            
            # -- 2º Step - Liberar as variáveis 
            # Cálculo da probabilidade baseada no volume de blocos (y_sol)
            blocos_por_esp = [sum(y_sol[i, r, u] for r in R, u in Uw) for i in I]   # Calcula o número de blocos de tempo de sala de cirurgia alocados para cada especialidade
            total_blocos = sum(blocos_por_esp)                                      # Calcula o número total de blocos de tempo de sala de cirurgia alocados para todas as especialidades
            if total_blocos <= 0                                                    # Caso não haja blocos de tempo de sala de cirurgia alocados para nenhuma especialidade, o operador não pode ser executado
                println("Número de OR time blocks insuficiente") 
                continue 
            end
            probabilidades = blocos_por_esp ./ total_blocos                         # Calcula a probabilidade de cada especialidade ser selecionada para remoção, proporcional ao número de blocos de tempo de sala de cirurgia alocados para cada especialidade
            selected_specialty = sample(1:nb_specialties, Weights(probabilidades))  # Seleciona-se uma especialidade para remoção, com base nas probabilidades calculadas

            # Libera especialidade nas salas/horários onde ela já estava ou pode estar
            for r in R, u in Uw                                     # Para cada sala e bloco de tempo 
                unfix(y[selected_specialty, r, u])                  # Remove-se a restrição a especialidade selecionad
                push!(last_unfixed_y, (selected_specialty, r, u))   # Adiciona a variável à lista de variáveis liberadas
            end
            for j in J_by_i[selected_specialty], u in Uw    # Para cada paciente da especialidade selecionada e cada bloco de tempo
                unfix(v[j, u])                              # -- Remove-se a restrição de alocação do paciente
                push!(last_unfixed_v, (j, u))               # -- Adiciona a variável à lista de variáveis liberadas
                for r in R                                  # Para cada sala de operações
                    unfix(x[j, r, u])                       # -- Remove-se a restrição de alocação do paciente na sala
                    push!(last_unfixed_x, (j, r, u))        # -- Adiciona a variável à lista de variáveis liberadas
                end
            end
        ##################################################################
        elseif destroy_operator == 2
        ##################################################################
            # Destroy 2 - Remover duas especialidades da solução
            # -- 1º Step - Fixar as variáveis da iteração anterior
            refix_last_neighborhood!(x, y, v, x_sol, y_sol, v_sol, last_unfixed_x, last_unfixed_y, last_unfixed_v)

            # -- 2º Step - Liberar as variáveis 
            blocos_por_esp = [sum(y_sol[i, r, u] for r in R, u in Uw) for i in I]   # Calcula o número de blocos de tempo de sala de cirurgia alocados para cada especialidade
            total_blocos = sum(blocos_por_esp)                                      # Calcula o número total de blocos de tempo de sala de cirurgia alocados para todas as especialidades
            if total_blocos <= 0                                                    # Caso não haja blocos de tempo de sala de cirurgia alocados para nenhuma especialidade, o operador não pode ser executado
                println("Número de OR time blocks insuficiente") 
                continue 
            end
            probabilidades = blocos_por_esp ./ total_blocos                                                 # Calcula-se as probabilidades de seleção
            selected_specialties = sample(1:nb_specialties, Weights(probabilidades), 2, replace = false)    # Seleciona-se duas especialidades para remoção, com base nas probabilidades calculadas
            
            # Libera as variáveis
            for r in R, u in Uw, i in selected_specialties              # Para cada sala, bloco de tempo e especialidade selecionada
                unfix(y[i, r, u])                                       # -- Remove-se a restrição de alocação da especialidade na sala e bloco de tempo
                push!(last_unfixed_y, (i, r, u))                        # -- Adiciona a variável à lista de variáveis liberadas
            end
            for i in selected_specialties, j in J_by_i[i], u in Uw      # Para cada especialidade selecionada, paciente da especialidade e bloco de tempo
                unfix(v[j, u])                                          # -- Remove-se a restrição de alocação do paciente
                push!(last_unfixed_v, (j, u))                           # -- Adiciona a variável à lista de variáveis liberadas
                for r in R                                              # Para cada sala de operações
                    unfix(x[j, r, u])                                   # -- Remove-se a restrição de alocação do paciente na sala
                    push!(last_unfixed_x, (j, r, u))                    # -- Adiciona a variável à lista de variáveis liberadas
                end
            end
        ##################################################################
        elseif destroy_operator == 3          
        ##################################################################
            # # Destroy 3 - Liberar duas salas inteiras de acordo com a folga
            # -- 1º Step - Calcular a folga de cada sala considerando o tempo nominal e o desvio robusto
            ociosidade = Float64[]  # Vetor para salvar a ociosidade de cada sala
            for r in R              # Para cada sala, calcula-se a ociosidade considerando o tempo nominal e o desvio robusto
                folga_sala = 0.0    # Salva-se a ociosidade da sala r
                for u in Uw         # Para cada turno 
                    # 1. Filtra pacientes alocados
                    indices_pacientes = [j for j in J if x_sol[j,r,u] > 0.5]    # Salva os indices de todos os pacientes alocados ao bloco (r,u)
                    if isempty(indices_pacientes) continue end                  # Se o bloco for vazio, continue -- TODO - Poderia penalizar depois as salas não ocupadas

                    # 2. Soma o tempo nominal de todos os pacientes alocados nessa sala/slot
                    tempo_nominal = sum(tempo_OR[j] for j in indices_pacientes)

                    # 3. Soma o tempo de desvio de todos os pacientes alocados nessa sala/slot (caso sejam considerados desvios)
                    desvio_robusto = 0
                    if Γ1 > 0
                        desvios = partialsort!([desvio_OR[j] for j in indices_pacientes], 1: min(length(indices_pacientes), Γ1), rev=true)  # Salva os maiores desvios
                        desvio_robusto = sum(desvios)                                                                                       # Soma os maiores desvios
                    end

                    # 4. Calcula a folga considerando o tempo nominal e o desvio robusto
                    tempo_total = tempo_nominal + desvio_robusto            # Tempo total é o nominal + budget
                    folga_total = capacidade_OR - tempo_total               # Folga total é a diferença entre capacidade e utilização
                    folga_sala += folga_total < 1e-7 ? 0.0 : folga_total    # Soma zero caso não exista folga, soma folga caso exista
                end
                push!(ociosidade, folga_sala)                               # Salva a ociosidade da sala em um vetor
            end    
            
            # Verifica se há salas com ociosidade suficiente para serem liberadas
            ociosidade_total = sum(ociosidade)
            if ociosidade_total < 1e-7 || count(x -> x > 0, ociosidade) < 2 # Caso a ociosidade for zero ou houver menos de duas salas com ociosidade, o operador não pode ser executado
                println("Número de OR time blocks insuficiente") 
                continue 
            end

            # -- 2º Step - Selecionar as salas a liberar com base na ociosidade (maior ociosidade, maior a probabilidade de ser selecionada)
            probabilidades = ociosidade ./ ociosidade_total                             # Calcula-se as probabilidades de seleção das salas com base na ociosidade
            selected_rooms = sample(R, Weights(probabilidades), 2, replace = false)     # Seleciona-se duas salas para remoção, com base nas probabilidades calculadas
            
            # -- 3º Step - Travar as variáveis liberadas na iteração anterior
            refix_last_neighborhood!(x, y, v, x_sol, y_sol, v_sol, last_unfixed_x, last_unfixed_y, last_unfixed_v)

            # Libera as variáveis
            for j in J, u in Uw                         # Para cada paciente e cada bloco de tempo
                unfix(v[j, u])                          # Libera-se todos os pacientes para permitir a realocação
                push!(last_unfixed_v, (j, u))           # Salvar quem foi liberado
                for r in selected_rooms                 # Para cada sala selecionada
                    unfix(x[j, r, u])                   # Libera-se os pacientes alocados (aos pacientes alocados em outro sala, v[j,u] continua vinculado, mesmo liberando-o)
                    push!(last_unfixed_x, (j, r, u))    # Salvar quem foi liberado
                end
            end
        ##################################################################
        elseif destroy_operator == 4
        ##################################################################
            # # Destroy 4 - Liberar duas salas inteiras de acordo com o tempo de espera
            # -- 1º Step - Fixar as variáveis
            refix_last_neighborhood!(x, y, v, x_sol, y_sol, v_sol, last_unfixed_x, last_unfixed_y, last_unfixed_v)

            # 1. Pré-alocação (Criando estruturas para salvar as informações pertinentes)
            waiting_time_by_specialty = zeros(Float64, nb_specialties)              # Vetor para salvar o tempo de espera por especialidade
            wt_by_OR_spec = zeros(Float64, nb_rooms, length(U), nb_specialties)     # Matriz para salvar o tempo de espera por sala, turno e especialidade

            # 2. Computar tempos
            penalty_not_allocated = length(U) + 1       # Penalidade por não alocação
            for i in I                                  # Para cada especialidade
                for j in J_by_i[i]                      # Para cada paciente da especialidade i
                    allocated_to_u = -1                 # Variável para salvar o turno em que o paciente j foi alocado
                    for u in Uw                         # Para cada turno
                        if v_sol[j, u] > 0.5            # Se o paciente está alocado ao turno
                            allocated_to_u = u          # Salvar a informação do turno
                            waiting_time_by_specialty[i] += tempo_espera[j] + u     # Salva o tempo de espera do paciente j na especialidade i
                            for r in R                                              # Para cada sala
                                if x_sol[j, r, u] > 0.5                             # Se o paciente j está alocado na sala r no turno u
                                    wt_by_OR_spec[r, u, i] += tempo_espera[j]       # Salva o tempo de espera do paciente j na especialidade i, na sala r e no turno u
                                    break
                                end
                            end
                            break                       # Sai do loop de turnos, pois o paciente j já foi alocado a um turno
                        end
                    end
                    #
                    if allocated_to_u == -1             # Se o paciente j não foi alocado a nenhum turno, adiciona-se a penalidade por não alocação ao tempo de espera da especialidade i
                        waiting_time_by_specialty[i] += tempo_espera[j] + penalty_not_allocated
                    end
                end
            end

            # 3. Seleção de Especialidades
            espera_total = sum(waiting_time_by_specialty)                   # Tempo de espera total
            if espera_total > 1e-6                                          # Se existe espera
                prob_esp = waiting_time_by_specialty ./ espera_total        # Calcula-se as probabilidades de seleção das especialidades com base no tempo de espera 
                num_esp_considerar = sample(1:nb_specialties, Weights(prob_esp), rand(1:nb_specialties), replace = false)   # Determina-se o número de especialidades a serem consideradas para destruição, com base nas probabilidades calculadas
                for i in num_esp_considerar
                    # Filtra apenas blocos da especialidade i que têm pacientes (tempo > 0)
                    available_blocks = [(r, u) for r in R, u in Uw if wt_by_OR_spec[r, u, i] > 0]       # Salva os blocos de tempo (sala, turno) da especialidade i que têm pacientes alocados (tempo de espera > 0)
                    if length(available_blocks) >= 2                                                    # Se existem pelo menos 2 blocos de tempo disponíveis para a especialidade i, seleciona-se 2 blocos para destruição
                        wts = [wt_by_OR_spec[r, u, i] for (r, u) in available_blocks]                   # Salva os tempos de espera dos blocos de tempo disponíveis para a especialidade i

                        # Seleciona 2 blocos para destruir
                        selected_OR = sample(available_blocks, Weights(wts), 2, replace = false)        # Seleciona-se 2 blocos de tempo (sala, turno) para destruição, com base nos tempos de espera dos blocos disponíveis
                        for (r, u) in selected_OR                   # Para cada bloco de tempo selecionado (sala, turno)
                            if is_fixed(y[i,r,u])                   # Se a especialidade i está alocada na sala r no turno u, libera-se a variável y[i,r,u]
                                unfix(y[i, r, u])                   # Libera a variável y[i, r, u]
                                push!(last_unfixed_y, (i, r, u))    # Salve as alterações feitas
                            end
                            #
                            for j in J_by_i[i]                          # Para cada paciente
                                if is_fixed(x[j, r, u])                 # Se o paciente está fixo
                                    unfix(x[j, r, u])                   # Libere o paciente e salve a alteração
                                    push!(last_unfixed_x, (j, r, u))
                                    #
                                    if is_fixed(v[j,u])                 # Se o paciente está fixo
                                        unfix(v[j, u])                  # Libere o paciente e salve a alteração
                                        push!(last_unfixed_v, (j, u))
                                    end
                                end
                            end
                        end
                    end
                end
            end
        ##################################################################
        else
        ##################################################################
            # Destroy 5 - Liberar as alocações de pacientes/salas que inflam a utilização dos ICUs
            utilizacao = [max(0, sum(value(robustez_ICU[u]) for u in (4*(d-1) + 1):(4*(d-1) + 2))) for d in 1:nb_days if is_workday(d)] # Calcula a utilização da UTI por dia, considerando apenas os dias úteis
            utilizacao_total = sum(utilizacao)                  # Soma a utilização total ao longo do horizonte de planejamento
            if utilizacao_total == 0                            # Se não houver utilização, o operador não pode ser executado
                println("Número de ICU beds insuficiente") 
                continue 
            end

            # Calcula-se a probabilidade, seleciona-se um dia e libera-se os pacientes que contribuem para a utilização da UTI nesse dia e seus semelhantes de tupla (r,u)
            probabilidades = utilizacao ./ utilizacao_total                                         # Calcula a probabilidade de seleção de cada dia
            selected_day = sample([d for d in 1:nb_days if is_workday(d)], Weights(probabilidades)) # Seleciona o dia de acordo com a probabilidade
            u_selected = (4*(selected_day-1)+1):(4*(selected_day-1)+2)                              # Turnos selecionados de acordo com o dia sortedo
            salas_turnos_alvo = Set{Tuple{Int, Int}}()                                              # Vetor para salvar as salas
            for j in J                                                              # Para cada paciente
                precisa_ICU[j] || continue                                          # Se o paciente não precisa de UTI, continue para o próximo paciente
                # Se o paciente j contribui para a UTI nos turnos críticos...   
                for r in R, u in u_selected, u1 in Uw                               # Para cada sala, verifica-se em qual tupla (r,u) os pacientes que ocupam UTI foram alocados
                    if x_sol[j, r, u1] > 0.9 && (u1 > u - tempo_ICU[j] - desvio_ICU[j] && u1 <= u - tempo_ICU[j]) 
                        push!(salas_turnos_alvo, (r, u1))
                        break
                    end
                end
            end

            # Fixar as variáveis anteriormente liberadas
            refix_last_neighborhood!(x, y, v, x_sol, y_sol, v_sol, last_unfixed_x, last_unfixed_y, last_unfixed_v)

            # Liberar as variáveis de interesse
            for (r, u) in salas_turnos_alvo
                for i in I
                    unfix(y[i, r, u])
                    push!(last_unfixed_y, (i, r, u))
                end
                for j in J
                    if is_fixed(v[j,u])
                        unfix(v[j, u])
                        push!(last_unfixed_v, (j, u))
                    end
                    unfix(x[j, r, u])
                    push!(last_unfixed_x, (j, r, u)) 
                end
            end
        end

        # Atualizando parametros
        operador_utilizacao[destroy_operator] += 1
        operador_utilizacao_ciclo[destroy_operator] += 1

        # Otimizando
        # -- 2º Step - Otimizar o modelo
        optimize!(model)
        status = termination_status(model)
        println("Status da solução robusta: ", status)

        # Verificando a viabilidade do modelo e imprimindo informações no console
        if (status != MOI.INFEASIBLE && status != MOI.OBJECTIVE_LIMIT) && result_count(model) > 0
            println("Status da solução robusta: ", termination_status(model))
            println("Objective Value: ", objective_value(model))
            infeasible_solution = false
        else
            println("Nenhuma solução viável encontrada nesta iteração.")
            loop += 1
            iteracao += 1
            continue
        end

        # Verificador de qualidade da solução
        solucao_encontrada = objective_value(model)
        if solucao_encontrada < ciclo_obj_value                             # Se a solução atual é melhor que a melhor solução local
            println("-- UMA SOLUÇÃO MELHOR QUE A CORRENTE FOI ACEITA")      # Imprime informações e salva as variáveis de decisão
            x_sol = JuMP.value.(model[:x])
            y_sol = JuMP.value.(model[:y])
            v_sol = JuMP.value.(model[:v])
            ciclo_obj_value = solucao_encontrada

            # Verificando a qualidade frente a melhor solução conhecida
            if solucao_encontrada < best_obj_value                          # Se a solução atual é melhor que a melhor solução global 
                loop = 0                                                    # Reseta o contador de não melhorias, imprime informações e salva as variáveis de decisão
                println("-- MELHOR SOLUÇÃO ENCONTRADA PELO ALGORITMO!!")
                println("-- Best Sol.: $best_obj_value -- Best Sol. Corrente: $ciclo_obj_value -- Solução encontrada: $solucao_encontrada")
                x_best = x_sol
                y_best = y_sol
                v_best = v_sol            
                best_obj_value = solucao_encontrada
            else                                                            # Se a solução não melhora a melhor solução global
                loop += 1                                                   # Incrementa o contador de não melhorias e imprime informações
                println("-- Best Sol.: $best_obj_value -- Best Sol. Corrente: $ciclo_obj_value -- Solução encontrada: $solucao_encontrada")
            end

            # Contabiliza a utilização dos operadores
            operador_melhoria[destroy_operator] += 1
            operador_melhoria_ciclo[destroy_operator] += 1
        else                                                                # Se a solução não melhora nenhuma das soluções conhecidas
            loop += 1                                                       # Incrementa o contador de não melhorias e imprime informações
            println("\n\n\n-- A SOLUÇÃO ENCONTRADA NÃO É MELHOR")
            println("-- Best Sol.: $best_obj_value -- Best Sol. Corrente: $ciclo_obj_value -- Solução encontrada: $solucao_encontrada")
        end
        
        # Imprime informações importantes para cada iteração do algoritmo
        println("\n\n -- Indicadores durante toda a heurística")
        println("Utilização dos operadores: ", operador_utilizacao)
        println("Melhoria graças aos operadores: ", operador_melhoria)
        println("-- Indicadores durante o atual ciclo da heurística")
        println("Utilização dos operadores: ", operador_utilizacao_ciclo)
        println("Melhoria graças aos operadores: ", operador_melhoria_ciclo)
        println("Pesos atuais: ", pesos_operador)
        println("Probabilidades atuais: ", probabilidade_operador)

        # A cada T2 iterações, verificar se o modelo será reiniciado (i.e., os logs guardados pelo Gurobi serão descartados e a busca começará do zero)
        if iteracao % T2 == 0
            # Verificando se o modelo será reiniciado
            p_reset = loop/10
            println("\n\n\n-- Probabilidade de resetar o modelo: ", p_reset)
            if rand() < p_reset
                println("\n\n\n-- Reiniciando o modelo matemático...")
                grb_model = backend(model).optimizer.model
                GRBreset(grb_model, 0)
                reset = true
            else
                println("\n\n\n-- O modelo matemático NÃO será reiniciado...")
            end

            #
            println("\n\n\n-- Atualizando os pesos dos operadores...")
            println("Pesos atualizados...")
            ρ = 0.2
            for u in 1:5
                if operador_utilizacao_ciclo[u] == 0
                    peso_atualizado = (1 - ρ)*pesos_operador[u]
                    pesos_operador[u] = peso_atualizado
                else
                    peso_atualizado = (1 - ρ)*pesos_operador[u] + ρ*(operador_melhoria_ciclo[u]/operador_utilizacao_ciclo[u])
                    pesos_operador[u] = peso_atualizado
                    operador_melhoria_ciclo[u] = 0
                    operador_utilizacao_ciclo[u] = 0
                end
            end
            soma_pesos = sum(pesos_operador)
            for u in 1:5
                probabilidade_operador[u] = pesos_operador[u] / soma_pesos
            end
            println("Probabilidades atuais(normalizados): ", probabilidade_operador)
        end

        #
        iteracao += 1
    end

    return model, init_time, best_obj_value, x_best, y_best, v_best, δ, iteracao, operador_utilizacao, operador_melhoria
end

function refix_last_neighborhood!(x, y, v, x_sol, y_sol, v_sol, last_unfixed_x, last_unfixed_y, last_unfixed_v)
    # Refixa y
    for (i, r, u) in last_unfixed_y
        fix(y[i,r,u], y_sol[i,r,u]; force = true)
    end

    # Refixa x
    for (j, r, u) in last_unfixed_x
        fix(x[j,r,u], x_sol[j,r,u]; force = true)
    end

    # Refixa v
    for (j, u) in last_unfixed_v
        fix(v[j,u], v_sol[j,u]; force = true)
    end

    empty!(last_unfixed_y)
    empty!(last_unfixed_x)
    empty!(last_unfixed_v)

    return nothing
end