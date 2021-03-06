# Copyright 2019 Observational Health Data Sciences and Informatics
#
# This file is part of Covid19EstimationHydroxychloroquine
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

#' @export
doNegativeControlCalibration <- function(studyFolder,
                           databaseIds,
                           analysisIds,
                           maxCores) {

  outcomesOfInterest <- getOutcomesOfInterest()
  negativeControlOutcome <- getAllControls() %>% filter(targetEffectSize == 1)

for(databaseId in databaseIds){
  singleCohortMethodResult<-readRDS(file.path(studyFolder,"shinyData",sprintf("cohort_method_result_%s.rds",databaseId)))
  colnames(singleCohortMethodResult)<-SqlRender::snakeCaseToCamelCase(colnames(singleCohortMethodResult))
  tcos <- unique(singleCohortMethodResult[, c("targetId", "comparatorId", "outcomeId")])
  tcos <- tcos[tcos$outcomeId %in%  outcomesOfInterest, ]
  tcs<-unique(tcos[,c("targetId","comparatorId")])

  for (analysisId in unique(analysisIds)){
    for (i in seq(nrow(tcs))){
      tc<- tcs[i,]
      index<-singleCohortMethodResult$targetId==tc$targetId&
        singleCohortMethodResult$comparatorId==tc$comparatorId&
        singleCohortMethodResult$analysisId==analysisId&
        singleCohortMethodResult$databaseId==databaseId&
        !is.na(singleCohortMethodResult$logRr) &
        !is.na(singleCohortMethodResult$seLogRr)

      if(sum(index, na.rm=T)==0) next
      negativeData<-singleCohortMethodResult[index &
                                               singleCohortMethodResult$outcomeId %in% unique(negativeControlOutcome$outcomeId),]
      null<-EmpiricalCalibration::fitNull(negativeData$logRr,
                                          negativeData$seLogRr)

      model<-EmpiricalCalibration::convertNullToErrorModel(null)

      calibratedCi<-EmpiricalCalibration::calibrateConfidenceInterval(logRr=singleCohortMethodResult[index,]$logRr,
                                                                      seLogRr=singleCohortMethodResult[index,]$seLogRr,
                                                                      model=model,
                                                                      ciWidth = 0.95)

      singleCohortMethodResult[index,]$calibratedLogRr<-calibratedCi$logRr
      singleCohortMethodResult[index,]$calibratedSeLogRr<-calibratedCi$seLogRr
      singleCohortMethodResult[index,]$calibratedCi95Lb<-exp(calibratedCi$logLb95Rr)
      singleCohortMethodResult[index,]$calibratedCi95Ub<-exp(calibratedCi$logUb95Rr)
      singleCohortMethodResult[index,]$calibratedRr<-exp(calibratedCi$logRr)

    }
  }
  colnames(singleCohortMethodResult)<-SqlRender::camelCaseToSnakeCase(colnames(singleCohortMethodResult))
  saveRDS(singleCohortMethodResult,file.path(studyFolder,"shinyData",sprintf("cohort_method_result_%s.rds",databaseId)))
}
}


#' @export
doMetaAnalysis <- function(studyFolder,
                           outputFolders,
                           maOutputFolder,
                           maName = "Meta-analysis",
                           useImbalance = FALSE,
                           maxCores) {

  ParallelLogger::logInfo("Performing meta-analysis")
  shinyDataFolder <- file.path(maOutputFolder, "shinyData")
  if (!file.exists(shinyDataFolder)) {
    dir.create(shinyDataFolder, recursive = TRUE)
  }

  # get main results
  loadResults <- function(outputFolder) {  # outputFolder <- outputFolders[13]
    database <- basename(outputFolder)
    file <- list.files(file.path(outputFolder, "shinyData"), pattern = sprintf("cohort_method_result_%s.rds", database), full.names = TRUE)
    result <- readRDS(file)
    colnames(result) <- SqlRender::snakeCaseToCamelCase(colnames(result))
    ParallelLogger::logInfo("Loading ", file, " for meta-analysis")
    return(result)
  }
  allResults <- lapply(outputFolders, loadResults)
  allResults <- do.call(rbind, allResults)

  # # drop bad TAR in OptumEHR and poor death capture
  # drops <-
  #   (allResults$databaseId == "OptumEHR" & allResults$analysisId == 1) | # panther on-treatment
  #   (allResults$databaseId %in% c("CCAE", "DAGermany", "JMDC", "MDCD", "MDCR", "OptumEHR", "OpenClaims", "AmbEMR") & allResults$outcomeId %in% c(18, 19)) | # death, cv death
  #   (allResults$databaseId %in% c("AmbEMR", "CPRD", "DAGermany", "IMRD", "SIDIAP") & allResults$outcomeId %in% c(22, 13, 20, 21, 17, 8, 11)) # databases with no IP
  # allResults <- allResults[!drops, ]
  #
  # blind estimates that don't pass diagnostics
  
  if (useImbalance) {
    
    aceMonoId <- 143
    arbMonoId <- 144
    
    arbComboId <- 138
    ccbThzComboId <- 149
    
    blinds <- 
      (allResults$databaseId == "CUIMC" & allResults$analysisId == 5 &
         !(allResults$targetId == aceMonoId & allResults$comparatorId == arbMonoId)) |
      (allResults$databaseId == "CUIMC" & allResults$analysisId == 6 &
         (allResults$targetId == aceMonoId & allResults$comparatorId == arbMonoId)) |
      (allResults$databaseId == "VA-OMOP" & allResults$analysisId == 5 &
         (allResults$targetId == arbComboId & allResults$comparatorId == ccbThzComboId))
  
    allResults$rr[blinds] <- NA
    allResults$ci95Lb[blinds] <- NA
    allResults$ci95Ub[blinds] <- NA
    allResults$logRr[blinds] <- NA
    allResults$seLogRr[blinds] <- NA
    allResults$p[blinds] <- NA
    allResults$calibratedRr[blinds] <- NA
    allResults$calibratedCi95Lb[blinds] <- NA
    allResults$calibratedCi95Ub[blinds] <- NA
    allResults$calibratedLogRr[blinds] <- NA
    allResults$calibratedSeLogRr[blinds] <- NA
    allResults$calibratedP[blinds] <- NA
    
  }

  # controls
  allControls <- lapply(outputFolders, getAllControls)
  allControls <- do.call(rbind, allControls)
  allControls <- allControls[, c("targetId", "comparatorId", "outcomeId", "targetEffectSize")]
  allControls <- allControls[!duplicated(allControls), ]

  ncIds <- allControls$outcomeId[allControls$targetEffectSize == 1]
  allResults$type[allResults$outcomeId %in% ncIds] <- "Negative control"
  allResults$type[is.na(allResults$type)] <- "Outcome of interest"

  groups <- split(allResults, paste(allResults$targetId, allResults$comparatorId, allResults$analysisId), drop = TRUE)
  cluster <- ParallelLogger::makeCluster(min(maxCores, 12))
  results <- ParallelLogger::clusterApply(cluster,
                                          groups,
                                          computeGroupMetaAnalysis,
                                          shinyDataFolder = shinyDataFolder,
                                          allControls = allControls)
  ParallelLogger::stopCluster(cluster)
  results <- do.call(rbind, results)
  
  results <- results %>% mutate(databaseId = maName)
  colnames(results) <- SqlRender::camelCaseToSnakeCase(colnames(results))

  fileName <- file.path(maOutputFolder, paste0("cohort_method_results_", maName, ".csv"))
  write.csv(results, fileName, row.names = FALSE, na = "")
  fileName <- file.path(shinyDataFolder, paste0("cohort_method_result_", maName, ".rds"))
  results <- subset(results, select = -c(type, mdrr))
  saveRDS(results, fileName)

  database <- data.frame(database_id = maName,
                         database_name = maName,
                         description = maName,
                         is_meta_analysis = 1,
                         stringsAsFactors = FALSE)
  fileName <- file.path(shinyDataFolder, paste0("database_", maName, ".rds"))
  saveRDS(database, fileName)
}

computeGroupMetaAnalysis <- function(group,
                                     shinyDataFolder,
                                     allControls) {

  # group <- groups[["137 143 1"]]
  analysisId <- group$analysisId[1]
  targetId <- group$targetId[1]
  comparatorId <- group$comparatorId[1]
  ParallelLogger::logInfo("Performing meta-analysis for target ", targetId, ", comparator ", comparatorId, ", analysis", analysisId)
  outcomeGroups <- split(group, group$outcomeId, drop = TRUE)
  outcomeGroupResults <- lapply(outcomeGroups, computeSingleMetaAnalysis)

  groupResults <- do.call(rbind, outcomeGroupResults)

  ncs <- groupResults[groupResults$type == "Negative control", ]
  ncs <- ncs[!is.na(ncs$seLogRr), ]
  if (nrow(ncs) > 5) {
    null <- EmpiricalCalibration::fitMcmcNull(ncs$logRr, ncs$seLogRr) # calibrate CIs without synthesizing positive controls, assumes error consistent across effect sizes
    model <- EmpiricalCalibration::convertNullToErrorModel(null)
    calibratedP <- EmpiricalCalibration::calibrateP(null = null,
                                                    logRr = groupResults$logRr,
                                                    seLogRr = groupResults$seLogRr)
    calibratedCi <- EmpiricalCalibration::calibrateConfidenceInterval(logRr = groupResults$logRr,
                                                                      seLogRr = groupResults$seLogRr,
                                                                      model = model)
    groupResults$calibratedP <- calibratedP$p
    groupResults$calibratedRr <- exp(calibratedCi$logRr)
    groupResults$calibratedCi95Lb <- exp(calibratedCi$logLb95Rr)
    groupResults$calibratedCi95Ub <- exp(calibratedCi$logUb95Rr)
    groupResults$calibratedLogRr <- calibratedCi$logRr
    groupResults$calibratedSeLogRr <- calibratedCi$seLogRr
  } else {
    groupResults$calibratedP <- rep(NA, nrow(groupResults))
    groupResults$calibratedRr <- rep(NA, nrow(groupResults))
    groupResults$calibratedCi95Lb <- rep(NA, nrow(groupResults))
    groupResults$calibratedCi95Ub <- rep(NA, nrow(groupResults))
    groupResults$calibratedLogRr <- rep(NA, nrow(groupResults))
    groupResults$calibratedSeLogRr <- rep(NA, nrow(groupResults))
  }
  return(groupResults)
}

computeSingleMetaAnalysis <- function(outcomeGroup) {
  # outcomeGroup <- outcomeGroups[[1]]
  maRow <- outcomeGroup[1, ]
  outcomeGroup <- outcomeGroup[!is.na(outcomeGroup$seLogRr), ] # drops rows with zero events in T or C

  if (nrow(outcomeGroup) == 0) {
    maRow$targetSubjects <- 0
    maRow$comparatorSubjects <- 0
    maRow$targetDays <- 0
    maRow$comparatorDays <- 0
    maRow$targetOutcomes <- 0
    maRow$comparatorOutcomes <- 0
    maRow$rr <- NA
    maRow$ci95Lb <- NA
    maRow$ci95Ub <- NA
    maRow$p <- NA
    maRow$logRr <- NA
    maRow$seLogRr <- NA
    maRow$i2 <- NA
  } else if (nrow(outcomeGroup) == 1) {
    maRow <- outcomeGroup[1, ]
    maRow$i2 <- 0
  } else {
    maRow$targetSubjects <- sumMinCellCount(outcomeGroup$targetSubjects)
    maRow$comparatorSubjects <- sumMinCellCount(outcomeGroup$comparatorSubjects)
    maRow$targetDays <- sum(outcomeGroup$targetDays)
    maRow$comparatorDays <- sum(outcomeGroup$comparatorDays)
    maRow$targetOutcomes <- sumMinCellCount(outcomeGroup$targetOutcomes)
    maRow$comparatorOutcomes <- sumMinCellCount(outcomeGroup$comparatorOutcomes)
    meta <- meta::metagen(outcomeGroup$logRr, outcomeGroup$seLogRr, sm = "RR", hakn = FALSE)
    s <- summary(meta)
    maRow$i2 <- s$I2$TE
    
    rnd <- s$random
    maRow$rr <- exp(rnd$TE)
    maRow$ci95Lb <- exp(rnd$lower)
    maRow$ci95Ub <- exp(rnd$upper)
    maRow$p <- rnd$p
    maRow$logRr <- rnd$TE
    maRow$seLogRr <- rnd$seTE

    # if (maRow$i2 < .40) {
    #   rnd <- s$random
    #   maRow$rr <- exp(rnd$TE)
    #   maRow$ci95Lb <- exp(rnd$lower)
    #   maRow$ci95Ub <- exp(rnd$upper)
    #   maRow$p <- rnd$p
    #   maRow$logRr <- rnd$TE
    #   maRow$seLogRr <- rnd$seTE
    # } else {
    #   maRow$rr <- NA
    #   maRow$ci95Lb <- NA
    #   maRow$ci95Ub <- NA
    #   maRow$p <- NA
    #   maRow$logRr <- NA
    #   maRow$seLogRr <- NA
    # }
  }
  if (is.na(maRow$logRr)) {
    maRow$mdrr <- NA
  } else {
    alpha <- 0.05
    power <- 0.8
    z1MinAlpha <- qnorm(1 - alpha/2)
    zBeta <- -qnorm(1 - power)
    pA <- maRow$targetSubjects / (maRow$targetSubjects + maRow$comparatorSubjects)
    pB <- 1 - pA
    totalEvents <- abs(maRow$targetOutcomes) + abs(maRow$comparatorOutcomes)
    maRow$mdrr <- exp(sqrt((zBeta + z1MinAlpha)^2/(totalEvents * pA * pB)))
  }
  maRow$databaseId <- "Meta-analysis"
  maRow$sources <- paste(outcomeGroup$databaseId[order(outcomeGroup$databaseId)], collapse = ", ")
  return(maRow)
}

sumMinCellCount <- function(counts) {
  total <- sum(abs(counts))
  if (any(counts < 0)) {
    total <- -total
  }
  return(total)
}

getAllControls <- function(outputFolder) {
  pathToCsv <- system.file("settings", "NegativeControls.csv", package = "Covid19IncidenceAlphaBlockers")
  allControls <- read.csv(pathToCsv)
  allControls$oldOutcomeId <- allControls$outcomeId
  allControls$targetEffectSize <- rep(1, nrow(allControls))
  return(allControls)
}
